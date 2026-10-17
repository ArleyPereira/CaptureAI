import AppKit
import Foundation
import Observation
import SwiftUI

/// Idiomas disponíveis na tela de configurações.
enum TranscriptionLanguageOption: String, CaseIterable, Identifiable {
    case portuguese = "pt"
    case english = "en"
    case spanish = "es"
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .portuguese: return "Português (pt)"
        case .english: return "English (en)"
        case .spanish: return "Español (es)"
        case .auto: return "Detectar automaticamente"
        }
    }
}

/// Sub-abas dentro de Modelos.
enum ModelsPane: String, CaseIterable, Identifiable {
    case api
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .api: return "API"
        case .local: return "Local"
        }
    }

    var icon: String {
        switch self {
        case .api: return "key.fill"
        case .local: return "internaldrive.fill"
        }
    }
}

/// ViewModel da janela de configurações.
@Observable
@MainActor
final class SettingsViewModel {
    private let settings: AppSettings
    let parakeetModelStore: LocalParakeetModelStore
    let ctcModelStore: LocalCtcModelStore
    let historyStore: TranscriptionHistoryStore
    let wordReplacementStore: WordReplacementStore
    let clipboardStore: ClipboardHistoryStore
    let screenshotStore: ScreenshotStore
    let captureCoordinator: ScreenCaptureCoordinator

    /// Janela AppKit que hospeda as configurações (para centralizar diálogos filhos).
    weak var hostWindow: NSWindow?

    /// Notifica o AppState para liberar o modelo local quando a política muda.
    var onTranscriptionPolicyChanged: () -> Void

    /// Notifica o AppDelegate para re-registrar o atalho de captura.
    var onCaptureHotkeyChanged: () -> Void

    /// Aviso na base do painel: "desfazer" de uma exclusão ou confirmação de cópia.
    var toast: PanelToast?
    @ObservationIgnored fileprivate var toastDismissTask: Task<Void, Never>?

    /// Notifica a janela para aplicar Sistema / Claro / Escuro.
    var onAppearanceThemeChanged: () -> Void

    /// Notifica o AppState para mostrar/esconder a barra conforme o estilo.
    var onRecordingHUDStyleChanged: () -> Void

    /// Pede ao AppState uma ditagem cujo texto volta para um campo do app.
    ///
    /// O `Bool` pede o texto **cru**, sem substituição de palavras. A conclusão
    /// vem com `nil` quando não houve texto (cancelado, silêncio, erro) — é o
    /// que tira o campo do estado "gravando".
    var onFieldDictationRequested: (Bool, @escaping (String?) -> Void) -> Void

    /// Encerra a ditagem de campo em andamento e transcreve.
    var onFieldDictationStopRequested: () -> Void

    /// Descarta a ditagem de campo em andamento sem transcrever.
    var onFieldDictationCancelRequested: () -> Void

    /// Toca (ou encerra) o áudio de uma entrada do histórico na barra flutuante.
    var onHistoryAudioPlayRequested: (UUID, URL) throws -> Void

    /// Encerra a reprodução em andamento.
    var onHistoryAudioStopRequested: () -> Void

    /// Id da entrada tocando agora (`nil` = nenhuma).
    var playingHistoryEntryID: () -> UUID?

    /// Notifica o AppState para re-registrar o atalho global.
    var onDictationHotkeyChanged: () -> Void

    /// `true` = captura ativa (pausar atalho global); `false` = retomou.
    var onHotkeyCaptureSessionChanged: (Bool) -> Void

    /// Incrementado quando o macOS muda claro/escuro — força o SwiftUI a
    /// reler `resolvedColorScheme` com a preferência em “Sistema”.
    private(set) var systemAppearanceEpoch = 0

    /// Texto digitado no campo (nunca logado).
    var apiKeyDraft: String = ""

    /// Mensagem de status da última ação de salvar/remover.
    var statusMessage: String?

    /// Indica se a última ação foi bem-sucedida.
    var didSucceedLastAction = false

    /// Permissões do sistema, relidas ao abrir/voltar para a janela.
    private(set) var isAccessibilityTrusted = false
    private(set) var isMicrophoneAuthorized = false

    /// Espelho de `SMAppService` — o CaptureAI abre no login do macOS.
    var opensAtLogin = false

    /// Aviso quando o macOS pede aprovação ou o app não está em Aplicativos.
    private(set) var launchAtLoginHint: String?

    /// Escutando teclas para definir um novo atalho.
    var isCapturingHotkey = false

    /// Dica durante/após a captura do atalho.
    var hotkeyCaptureHint: String?

    /// Monitor local de teclado durante a captura.
    private var hotkeyCaptureMonitor: Any?

    /// Aba ativa da janela de configurações.
    ///
    /// Fica aqui, e não em `@State` da view, para quem abre a janela poder
    /// escolher onde ela começa — o menu da barra de status abre no Histórico.
    var selectedTab: SettingsTab = .general

    /// Sub-aba ativa em Modelos.
    var selectedModelsPane: ModelsPane = .api

    /// Modal de substituição de palavras aberta sobre as configurações.
    var isShowingWordReplacements = false

    /// Confirmação da última importação, exibida no card da aba Transcrição.
    private(set) var wordReplacementImportMessage: String?

    /// `true` enquanto o campo "Original" está gravando.
    ///
    /// Só ele tem microfone: a substituição é a grafia que o usuário decide,
    /// então tem de ser digitada exatamente como ele quer — ditá-la só traria
    /// de volta o palpite do modelo, que é justamente o que se quer corrigir.
    private(set) var isDictatingOriginal = false

    /// Grava pelo microfone e devolve o texto ao campo "Original".
    ///
    /// Clicar de novo no microfone encerra a gravação — mesmo gesto do atalho
    /// global, sem precisar mirar na barra flutuante.
    func dictateOriginal(onText: @escaping (String) -> Void) {
        if isDictatingOriginal {
            onFieldDictationStopRequested()
            return
        }

        isDictatingOriginal = true
        // O campo "Original" guarda a grafia **errada** do modelo; corrigi-la na
        // captura tornaria impossível cadastrá-la — daí o texto cru.
        onFieldDictationRequested(true) { [weak self] text in
            guard let self else { return }
            self.isDictatingOriginal = false
            guard let text = Self.cleanedDictation(text) else { return }
            onText(text)
        }
    }

    /// Descarta a gravação em andamento sem preencher campo nenhum.
    func cancelFieldDictation() {
        guard isDictatingOriginal else { return }
        onFieldDictationCancelRequested()
    }

    /// Prepara o texto ditado para um campo de uma palavra ou expressão curta.
    ///
    /// O modelo devolve a frase pontuada ("Branch."); num campo de vocabulário
    /// a pontuação final é ruído e entraria no cadastro.
    private static func cleanedDictation(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    init(
        settings: AppSettings,
        parakeetModelStore: LocalParakeetModelStore? = nil,
        ctcModelStore: LocalCtcModelStore? = nil,
        historyStore: TranscriptionHistoryStore? = nil,
        wordReplacementStore: WordReplacementStore? = nil,
        clipboardStore: ClipboardHistoryStore? = nil,
        screenshotStore: ScreenshotStore? = nil,
        captureCoordinator: ScreenCaptureCoordinator? = nil,
        onCaptureHotkeyChanged: @escaping () -> Void = {},
        onTranscriptionPolicyChanged: @escaping () -> Void = {},
        onAppearanceThemeChanged: @escaping () -> Void = {},
        onRecordingHUDStyleChanged: @escaping () -> Void = {},
        onDictationHotkeyChanged: @escaping () -> Void = {},
        onHotkeyCaptureSessionChanged: @escaping (Bool) -> Void = { _ in },
        onFieldDictationRequested: @escaping (Bool, @escaping (String?) -> Void) -> Void = { _, done in done(nil) },
        onFieldDictationStopRequested: @escaping () -> Void = {},
        onFieldDictationCancelRequested: @escaping () -> Void = {},
        onHistoryAudioPlayRequested: @escaping (UUID, URL) throws -> Void = { _, _ in },
        onHistoryAudioStopRequested: @escaping () -> Void = {},
        playingHistoryEntryID: @escaping () -> UUID? = { nil }
    ) {
        self.settings = settings
        self.parakeetModelStore = parakeetModelStore ?? .shared
        self.ctcModelStore = ctcModelStore ?? .shared
        self.historyStore = historyStore ?? .shared
        self.wordReplacementStore = wordReplacementStore ?? .shared
        self.clipboardStore = clipboardStore ?? .shared
        let screenshots = screenshotStore ?? ScreenshotStore(settings: settings)
        self.screenshotStore = screenshots
        self.captureCoordinator = captureCoordinator
            ?? ScreenCaptureCoordinator(settings: settings, store: screenshots)
        self.onCaptureHotkeyChanged = onCaptureHotkeyChanged
        self.onTranscriptionPolicyChanged = onTranscriptionPolicyChanged
        self.onAppearanceThemeChanged = onAppearanceThemeChanged
        self.onRecordingHUDStyleChanged = onRecordingHUDStyleChanged
        self.onDictationHotkeyChanged = onDictationHotkeyChanged
        self.onHotkeyCaptureSessionChanged = onHotkeyCaptureSessionChanged
        self.onFieldDictationRequested = onFieldDictationRequested
        self.onFieldDictationStopRequested = onFieldDictationStopRequested
        self.onFieldDictationCancelRequested = onFieldDictationCancelRequested
        self.onHistoryAudioPlayRequested = onHistoryAudioPlayRequested
        self.onHistoryAudioStopRequested = onHistoryAudioStopRequested
        self.playingHistoryEntryID = playingHistoryEntryID
        settings.refreshAPIKeyStatus()
        refreshPermissions()
        refreshLocalModelDiskState()
    }

    var hasAPIKey: Bool {
        settings.hasAPIKey
    }

    /// Tema da interface (Sistema / Claro / Escuro).
    var appearanceTheme: AppAppearanceTheme {
        get { AppAppearanceTheme(rawValue: settings.appearanceTheme) ?? .system }
        set {
            guard settings.appearanceTheme != newValue.rawValue else { return }
            settings.appearanceTheme = newValue.rawValue
            onAppearanceThemeChanged()
        }
    }

    /// Estilo da barra flutuante (Moderno / Clássico / Nenhuma).
    var recordingHUDStyle: RecordingHUDStyle {
        get { RecordingHUDStyle(rawValue: settings.recordingHUDStyle) ?? .moderno }
        set {
            guard settings.recordingHUDStyle != newValue.rawValue else { return }
            settings.recordingHUDStyle = newValue.rawValue
            onRecordingHUDStyleChanged()
        }
    }

    /// Atalho global de ditado escolhido pelo usuário.
    var dictationHotkey: DictationHotkey {
        settings.dictationHotkey
    }

    /// Inicia a escuta do novo atalho (Esc cancela).
    func beginHotkeyCapture() {
        guard !isCapturingHotkey else { return }
        isCapturingHotkey = true
        hotkeyCaptureHint = "Pressione o novo atalho… (Esc cancela)"
        onHotkeyCaptureSessionChanged(true)

        hotkeyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyCaptureEvent(event) ?? event
        }
    }

    /// Cancela a captura sem alterar o atalho atual.
    func cancelHotkeyCapture() {
        guard isCapturingHotkey else { return }
        endHotkeyCaptureSession(hint: nil)
    }

    /// Esconde a mensagem de feedback do atalho (sucesso / captura).
    func clearHotkeyCaptureHint() {
        hotkeyCaptureHint = nil
    }

    private func handleHotkeyCaptureEvent(_ event: NSEvent) -> NSEvent? {
        guard isCapturingHotkey else { return event }

        if event.keyCode == 53 { // Esc
            cancelHotkeyCapture()
            return nil
        }

        guard let hotkey = DictationHotkey.from(event: event) else {
            hotkeyCaptureHint = "Use um modificador (⌘ ⌥ ⇧ ⌃) + uma tecla."
            return nil
        }

        settings.dictationHotkey = hotkey
        onDictationHotkeyChanged()
        endHotkeyCaptureSession(hint: "Atalho atualizado para \(hotkey.displayName).")
        return nil
    }

    private func endHotkeyCaptureSession(hint: String?) {
        if let hotkeyCaptureMonitor {
            NSEvent.removeMonitor(hotkeyCaptureMonitor)
            self.hotkeyCaptureMonitor = nil
        }
        isCapturingHotkey = false
        hotkeyCaptureHint = hint
        onHotkeyCaptureSessionChanged(false)
    }

    /// Esquema SwiftUI correspondente (sempre concreto para atualizar na hora).
    var preferredColorScheme: ColorScheme {
        _ = systemAppearanceEpoch
        return appearanceTheme.resolvedColorScheme()
    }

    /// O macOS trocou claro/escuro — reaplica se a preferência for “Sistema”.
    func handleSystemAppearanceChanged() {
        systemAppearanceEpoch &+= 1
        guard appearanceTheme == .system else { return }
        onAppearanceThemeChanged()
    }

    var isTestModeEnabled: Bool {
        get { settings.isTestModeEnabled }
        set {
            settings.isTestModeEnabled = newValue
            // Modo teste não usa o modelo local: libera a RAM imediatamente.
            if newValue {
                onTranscriptionPolicyChanged()
            }
        }
    }

    var keepRecordingsAfterTranscription: Bool {
        get { settings.keepRecordingsAfterTranscription }
        set { settings.keepRecordingsAfterTranscription = newValue }
    }

    /// Quando `true`, ditagens reais entram no histórico local.
    var isTranscriptionHistoryEnabled: Bool {
        get { settings.isTranscriptionHistoryEnabled }
        set { settings.isTranscriptionHistoryEnabled = newValue }
    }

    var historyEntries: [TranscriptionHistoryEntry] {
        historyStore.entries
    }

    func deleteHistoryEntry(_ id: UUID) {
        historyStore.delete(id: id)
    }

    func deleteAllHistory() {
        historyStore.deleteAll()
    }

    func isPlayingHistoryAudio(_ id: UUID) -> Bool {
        playingHistoryEntryID() == id
    }

    /// - Throws: quando o `.m4a` não está mais no disco.
    func playHistoryAudio(_ entry: TranscriptionHistoryEntry) throws {
        guard let url = entry.audioURL else { return }
        try onHistoryAudioPlayRequested(entry.id, url)
    }

    func stopHistoryAudio() {
        onHistoryAudioStopRequested()
    }

    func copyHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    /// `true` quando o ditado usa o modelo local deste Mac.
    // MARK: - Substituição de palavras

    var wordReplacementCount: Int { wordReplacementStore.items.count }

    /// Resumo do card: quantidade cadastrada ou convite para criar a primeira.
    var wordReplacementSummary: String {
        switch wordReplacementCount {
        case 0: return "Nenhuma substituição cadastrada."
        case 1: return "1 substituição cadastrada."
        default: return "\(wordReplacementCount) substituições cadastradas."
        }
    }

    func reportWordReplacementImport(count: Int) {
        wordReplacementImportMessage = count == 1
            ? "1 substituição importada."
            : "\(count) substituições importadas."
    }

    func clearWordReplacementImportMessage() {
        wordReplacementImportMessage = nil
    }

    var usesLocalTranscription: Bool {
        get { settings.transcriptionBackend == "local" }
        set {
            let backend = newValue ? "local" : "api"
            guard settings.transcriptionBackend != backend else { return }
            settings.transcriptionBackend = backend
            if !newValue {
                onTranscriptionPolicyChanged()
            }
        }
    }

    var selectedLanguage: TranscriptionLanguageOption {
        get {
            TranscriptionLanguageOption(rawValue: settings.transcriptionLanguage) ?? .portuguese
        }
        set {
            settings.transcriptionLanguage = newValue.rawValue
        }
    }

    var apiKeyStatusLabel: String {
        hasAPIKey
            ? "Chave salva no Keychain"
            : "Nenhuma chave salva"
    }

    var modelLabel: String {
        TranscriptionConfiguration.model
    }

    var recordingsFolderPath: String {
        RecordingStorage.directoryURL.path
    }

    // MARK: - Modelo local (UI)

    var localStatusIsReady: Bool {
        parakeetModelStore.isDownloaded
    }

    var isLocalModelDownloaded: Bool {
        parakeetModelStore.isDownloaded
    }

    var isLocalModelDownloading: Bool {
        parakeetModelStore.isDownloading
    }

    var storageSummaryLabel: String {
        parakeetModelStore.onDiskByteCount.captureAIByteCountLabel
    }

    var downloadsFooterLabel: String {
        isLocalModelDownloaded ? "Em disco: \(storageSummaryLabel)" : "Nenhum modelo baixado"
    }

    var detailedDownloadProgress: (fraction: Double, percentLabel: String, speedLabel: String, sizeLabel: String)? {
        guard let progress = parakeetModelStore.downloadProgress else { return nil }
        return (
            progress.fractionCompleted,
            progress.percentLabel,
            progress.speedLabel,
            progress.sizeLabel
        )
    }

    func downloadLocalModel() {
        parakeetModelStore.download()
        Task { @MainActor in
            while parakeetModelStore.isDownloading {
                try? await Task.sleep(for: .milliseconds(200))
            }
            parakeetModelStore.refreshDiskState()
        }
    }

    func cancelLocalModelDownload() {
        parakeetModelStore.cancelDownload()
    }

    func deleteLocalModel() {
        do {
            // Solta o modelo da RAM antes de apagar o que está em disco.
            onTranscriptionPolicyChanged()
            try parakeetModelStore.delete()
        } catch {
            parakeetModelStore.reportError(error.localizedDescription)
        }
    }

    func refreshLocalModelDiskState() {
        parakeetModelStore.refreshDiskState()
        ctcModelStore.refreshDiskState()
    }

    // MARK: - Modelo CTC (substituição de palavras)

    var isCtcModelDownloaded: Bool {
        ctcModelStore.isDownloaded
    }

    var isCtcModelDownloading: Bool {
        ctcModelStore.isDownloading
    }

    var ctcStorageLabel: String {
        ctcModelStore.onDiskByteCount.captureAIByteCountLabel
    }

    /// O card precisa dizer se o download já serve para alguma coisa: baixado
    /// sem nenhuma substituição cadastrada não corrige nada.
    var ctcStatusLabel: String {
        guard isCtcModelDownloaded else { return "~98 MB · opcional" }
        let count = wordReplacementCount
        guard count > 0 else {
            return "\(ctcStorageLabel) · nenhuma substituição cadastrada"
        }
        return count == 1
            ? "\(ctcStorageLabel) · ativo em 1 substituição"
            : "\(ctcStorageLabel) · ativo em \(count) substituições"
    }

    var detailedCtcDownloadProgress: (fraction: Double, percentLabel: String, speedLabel: String, sizeLabel: String)? {
        guard let progress = ctcModelStore.downloadProgress else { return nil }
        return (
            progress.fractionCompleted,
            progress.percentLabel,
            progress.speedLabel,
            progress.sizeLabel
        )
    }

    func downloadCtcModel() {
        ctcModelStore.download()
        Task { @MainActor in
            while ctcModelStore.isDownloading {
                try? await Task.sleep(for: .milliseconds(200))
            }
            ctcModelStore.refreshDiskState()
        }
    }

    func cancelCtcModelDownload() {
        ctcModelStore.cancelDownload()
    }

    func deleteCtcModel() {
        do {
            // Solta o CTC da RAM antes de apagar o disco — ele fica quente junto
            // com o Parakeet, e apagar por baixo deixaria o carregado órfão.
            onTranscriptionPolicyChanged()
            try ctcModelStore.delete()
        } catch {
            ctcModelStore.reportError(error.localizedDescription)
        }
    }

    // MARK: - Permissões e pastas

    func refreshPermissions() {
        isAccessibilityTrusted = AccessibilityPermission.isTrusted
        isMicrophoneAuthorized = MicrophonePermission.isAuthorized
        refreshLaunchAtLogin()
    }

    /// Relê o status de início no login junto ao sistema.
    func refreshLaunchAtLogin() {
        opensAtLogin = LaunchAtLoginService.isEnabled
        launchAtLoginHint = LaunchAtLoginService.statusHint
    }

    /// Liga ou desliga a abertura automática no login.
    func setOpensAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLoginHint = nil
        } catch {
            launchAtLoginHint = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    /// Pendente: pede confiança e abre Ajustes. Já autorizada: só abre Ajustes.
    func handleAccessibilityAction() {
        if isAccessibilityTrusted {
            AccessibilityPermission.openSystemSettings()
        } else {
            AccessibilityPermission.requestAccess()
            AccessibilityPermission.openSystemSettings()
        }
    }

    func openMicrophoneSettings() {
        MicrophonePermission.openSystemSettings()
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(RecordingStorage.directoryURL)
    }

    func openLocalModelsFolder() {
        NSWorkspace.shared.open(parakeetModelStore.cacheDirectory)
    }

    /// Persiste a API key digitada.
    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Cole a API key da OpenAI antes de salvar."
            didSucceedLastAction = false
            return
        }

        do {
            try settings.saveOpenAIAPIKey(trimmed)
            apiKeyDraft = ""
            statusMessage = "API key salva com segurança no Keychain."
            didSucceedLastAction = true
        } catch {
            statusMessage = error.localizedDescription
            didSucceedLastAction = false
        }
    }

    /// Remove a API key do Keychain.
    func removeAPIKey() {
        do {
            try settings.deleteOpenAIAPIKey()
            apiKeyDraft = ""
            statusMessage = "API key removida."
            didSucceedLastAction = true
        } catch {
            statusMessage = error.localizedDescription
            didSucceedLastAction = false
        }
    }
}

// MARK: - Área de transferência e capturas

extension SettingsViewModel {
    var isClipboardHistoryEnabled: Bool {
        get { settings.isClipboardHistoryEnabled }
        set {
            guard settings.isClipboardHistoryEnabled != newValue else { return }
            settings.isClipboardHistoryEnabled = newValue
            if newValue {
                ClipboardMonitor.shared.start()
            } else {
                ClipboardMonitor.shared.stop()
            }
        }
    }

    var clipboardEntries: [ClipboardEntry] { clipboardStore.entries }

    /// Aplica os dois filtros da aba de texto.
    func filteredClipboardEntries(
        kind: ClipboardKind?,
        period: ClipboardPeriod,
        search: String
    ) -> [ClipboardEntry] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clipboardStore.entries.filter { entry in
            if let kind, entry.kind != kind { return false }
            guard period.contains(entry.createdAt) else { return false }
            guard !term.isEmpty else { return true }
            return entry.content.lowercased().contains(term)
        }
    }

    /// Copia de volta sem gerar um item novo no histórico.
    func copyClipboardEntry(_ entry: ClipboardEntry) {
        ClipboardMonitor.shared.copyWithoutRecording(entry.content)
        showToast(PanelToast(
            message: entry.kind == .link ? "Link copiado" : "Texto copiado",
            icon: "doc.on.doc"
        ))
    }

    func updateClipboardEntry(_ id: UUID, content: String) {
        clipboardStore.update(id: id, content: content)
    }

    func toggleClipboardPin(_ id: UUID) {
        clipboardStore.togglePin(id: id)
    }

    func deleteClipboardEntry(_ id: UUID) {
        guard let removed = clipboardStore.delete(id: id) else { return }
        offerUndo(removed.kind == .link ? "Link excluído" : "Texto excluído") { [weak self] in
            self?.clipboardStore.restore(removed)
        }
    }

    func clearClipboardHistory() {
        clipboardStore.deleteAll(keepingPinned: true)
    }

    // MARK: Capturas

    var screenshotEntries: [ScreenshotEntry] { screenshotStore.entries }

    var screenshotDirectoryLabel: String { settings.screenshotDirectoryDisplayPath }

    var captureHotkey: CaptureHotkey {
        get { settings.captureHotkey }
        set {
            guard settings.captureHotkey != newValue else { return }
            settings.captureHotkey = newValue
            onCaptureHotkeyChanged()
        }
    }

    func reloadScreenshots() {
        screenshotStore.reload()
    }


    /// Abre o seletor de pasta e passa a gravar as próximas capturas nela.
    ///
    /// Não move o que já foi salvo: os arquivos antigos continuam onde estão,
    /// e mexer neles por conta própria seria decidir pelo usuário.
    func chooseScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = screenshotStore.directoryURL
        panel.prompt = "Usar esta pasta"
        panel.message = "Escolha onde as próximas capturas serão salvas."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setScreenshotDirectory(url)
        screenshotStore.reload()
    }

    func resetScreenshotDirectory() {
        settings.setScreenshotDirectory(nil)
        screenshotStore.reload()
    }

    func openScreenshotDirectory() {
        screenshotStore.openDirectoryInFinder()
    }

    /// Abre no Quick Look em tela cheia, com as demais capturas a uma seta
    /// de distância, na ordem da lista.
    func openScreenshot(_ entry: ScreenshotEntry) {
        let urls = screenshotEntries.map(\.url)
        let index = urls.firstIndex(of: entry.url) ?? 0
        ScreenshotPreviewController.shared.show(urls, startingAt: index)
    }

    func revealScreenshot(_ entry: ScreenshotEntry) {
        screenshotStore.revealInFinder(entry)
    }

    func copyScreenshot(_ entry: ScreenshotEntry) {
        screenshotStore.copyToPasteboard(entry)
        showToast(PanelToast(message: "Imagem copiada", icon: "doc.on.doc"))
    }

    func deleteScreenshot(_ entry: ScreenshotEntry) {
        guard let trashed = screenshotStore.delete(entry) else { return }
        let original = entry.url
        offerUndo("Captura excluída") { [weak self] in
            self?.screenshotStore.restore(trashed: trashed, to: original)
        }
    }

    func deleteAllScreenshots() {
        screenshotStore.deleteAll()
    }

    // MARK: Avisos

    /// Mostra o aviso com "Desfazer". Uma exclusão nova substitui a anterior,
    /// que passa a valer de vez.
    private func offerUndo(_ message: String, undo: @escaping () -> Void) {
        showToast(PanelToast(message: message, icon: "trash", actionTitle: "Desfazer", action: undo))
    }

    /// Qualquer aviso novo substitui o que estiver na tela.
    private func showToast(_ toast: PanelToast) {
        self.toast = toast
        scheduleToastDismiss()
    }

    func performToastAction() {
        guard let toast, let action = toast.action else { return }
        toastDismissTask?.cancel()
        self.toast = nil
        action()
    }

    /// Pausa a contagem enquanto o mouse está sobre o aviso: quem está indo
    /// clicar não pode perder o botão no meio do caminho.
    func setToastHovered(_ hovering: Bool) {
        if hovering {
            toastDismissTask?.cancel()
        } else {
            scheduleToastDismiss()
        }
    }

    private func scheduleToastDismiss() {
        toastDismissTask?.cancel()
        guard let toast else { return }
        let id = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: toast.duration)
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }
}

/// Aviso na base do painel, com uma ação opcional.
struct PanelToast: Identifiable {
    let id = UUID()
    let message: String
    let icon: String
    var actionTitle: String?
    var action: (() -> Void)?

    /// Com ação, um pouco mais que os 3 s pedidos: é tempo de perceber o
    /// engano, levar o mouse até o botão e clicar. Sem ação é só uma
    /// confirmação, lida de relance.
    var duration: Duration {
        action == nil ? .seconds(2) : .seconds(4)
    }
}
