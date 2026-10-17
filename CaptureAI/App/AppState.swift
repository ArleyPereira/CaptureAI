import AppKit
import Foundation
import Observation
import OSLog

/// Fonte de verdade compartilhada do estado da aplicação.
@Observable
@MainActor
final class AppState {
    var recordingState: RecordingState = .idle {
        didSet { overlayController.sync(with: self) }
    }

    var lastRecordingURL: URL?
    var lastRecordingByteCount: Int?
    var lastCaptureDiagnostics: CaptureDiagnostics?
    var lastFocusedElementSummary: String?
    var lastInsertionMessage: String?
    var lastTranscriptionText: String?
    var permissionDeniedMessage: String?
    var lastHotkeyResultMessage: String?
    var isHotkeyMonitoringEnabled = false
    var isAccessibilityTrusted = AccessibilityPermission.isTrusted

    /// Configurações (API key no Keychain + idioma + guards de crédito).
    let settings: AppSettings

    /// Histórico local de transcrições.
    let historyStore: TranscriptionHistoryStore

    /// Nível de áudio espelhado no MainActor para animar a waveform.
    var displayedAudioLevel: Float = 0

    /// Duração da gravação atual formatada (m:ss).
    var recordingDurationText: String = "0:00"

    /// Texto da ditagem quando a inserção automática falhou (barra de resgate).
    var pendingDictationText: String?

    /// Reprodução do áudio de uma entrada do histórico.
    ///
    /// Divide a barra flutuante com a gravação. Nunca coexistem: começar a
    /// tocar com uma ditagem em curso seria disputar o mesmo espaço na tela e o
    /// mesmo par de botões.
    let playback = AudioPlaybackController()

    private let audioRecorder: any AudioRecorderProtocol
    private let hotkeyService: any GlobalHotkeyServiceProtocol
    /// Atalho da captura de tela, separado do de ditado.
    private let captureHotkeyService = CaptureHotkeyService()
    /// Observa a área de transferência do sistema.
    private let clipboardMonitor = ClipboardMonitor.shared
    /// Captura de tela: seleção, revisão e destino.
    let captureCoordinator: ScreenCaptureCoordinator
    let screenshotStore: ScreenshotStore
    private let accessibilityService: any AccessibilityServiceProtocol
    private let textInsertionService: any TextInsertionService
    private let transcriptionService: any TranscriptionService
    private let overlayController = RecordingOverlayController()
    private let settingsWindowController = SettingsWindowController()
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "pipeline")

    private var successResetTask: Task<Void, Never>?
    private var levelPollingTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    /// Tempo ativo já acumulado (exclui pausas).
    private var accumulatedRecordingDuration: TimeInterval = 0
    private var capturedFocusedElement: FocusedElement?
    /// Distingue gravação de menu (só mic) do push-to-talk (transcreve).
    private var isMicrophoneOnlyTest = false

    /// Para onde o texto vai quando a ditagem não é para o app em foco.
    ///
    /// Usado pelo microfone dos campos da substituição de palavras: o texto
    /// volta para quem pediu em vez de ser inserido no input do usuário.
    ///
    /// É chamado **exatamente uma vez** por captura, com `nil` quando não houve
    /// texto (cancelado, silêncio, erro). Sem essa garantia o campo ficaria
    /// preso no estado "gravando" para sempre.
    private var fieldCaptureHandler: ((String?) -> Void)?
    /// `false` enquanto a captura em curso quer o texto cru.
    private var appliesWordReplacementsInCapture = true

    /// `true` enquanto uma gravação está destinada a um campo do próprio app.
    ///
    /// A barra flutuante consulta isto para aparecer mesmo com o HUD desligado
    /// e para não roubar o foco do campo que disparou a gravação.
    private(set) var isCapturingForField = false

    /// Texto local só para o botão “Inserir texto de teste”.
    static let localInsertionTestText = "Olá, este é um teste do CaptureAI."

    init(
        audioRecorder: any AudioRecorderProtocol = AudioRecorder(),
        hotkeyService: any GlobalHotkeyServiceProtocol = GlobalHotkeyService(),
        accessibilityService: any AccessibilityServiceProtocol = AccessibilityService(),
        textInsertionService: (any TextInsertionService)? = nil,
        settings: AppSettings? = nil,
        transcriptionService: (any TranscriptionService)? = nil,
        historyStore: TranscriptionHistoryStore? = nil
    ) {
        self.audioRecorder = audioRecorder
        self.hotkeyService = hotkeyService
        self.accessibilityService = accessibilityService
        self.textInsertionService = textInsertionService
            ?? DefaultTextInsertionService(accessibilityService: accessibilityService)
        let resolvedSettings = settings ?? AppSettings()
        self.settings = resolvedSettings
        self.historyStore = historyStore ?? .shared
        self.transcriptionService = transcriptionService
            ?? CompositeTranscriptionService(settings: resolvedSettings)
        let screenshots = ScreenshotStore(settings: resolvedSettings)
        self.screenshotStore = screenshots
        self.captureCoordinator = ScreenCaptureCoordinator(
            settings: resolvedSettings,
            store: screenshots
        )
        refreshAccessibilityStatus()
        startHotkeyMonitoring()
        startCaptureHotkeyMonitoring()
        startClipboardMonitoringIfEnabled()
        warmLocalModelsIfNeeded()

        playback.onSessionChanged = { [weak self] in
            guard let self else { return }
            self.overlayController.sync(with: self)
        }
    }

    /// Toca o áudio ligado a uma entrada do histórico.
    ///
    /// Clicar de novo na mesma entrada encerra — o mesmo botão liga e desliga.
    ///
    /// - Throws: `AudioPlaybackController.StartError` quando o arquivo sumiu do
    ///   disco (o usuário pode ter apagado a gravação por fora).
    func playHistoryAudio(entryID: UUID, url: URL) throws {
        if playback.session?.entryID == entryID {
            playback.stop()
            return
        }
        // Uma ditagem em curso tem prioridade sobre ouvir uma antiga.
        guard recordingState == .idle else { return }
        try playback.play(entryID: entryID, url: url)
    }

    func stopHistoryAudio() {
        playback.stop()
    }

    /// Pré-aquece o Parakeet quando o backend local está ativo.
    func warmLocalModelsIfNeeded() {
        guard let composite = transcriptionService as? CompositeTranscriptionService else { return }
        composite.warmLocalModelsIfNeeded()
    }

    /// Abre a janela de Configurações (API key + idioma).
    func openSettingsWindow(tab: SettingsTab? = nil) {
        settingsWindowController.show(
            settings: settings,
            historyStore: historyStore,
            screenshotStore: screenshotStore,
            captureCoordinator: captureCoordinator,
            tab: tab,
            onCaptureHotkeyChanged: { [weak self] in
                self?.reloadCaptureHotkey()
            },
            onTranscriptionPolicyChanged: { [weak self] in
                self?.releaseLocalModelResources()
                self?.warmLocalModelsIfNeeded()
            },
            onRecordingHUDStyleChanged: { [weak self] in
                guard let self else { return }
                self.overlayController.sync(with: self)
            },
            onDictationHotkeyChanged: { [weak self] in
                self?.reloadDictationHotkey()
            },
            onHotkeyCaptureSessionChanged: { [weak self] isCapturing in
                if isCapturing {
                    self?.pauseHotkeyMonitoringForCapture()
                } else {
                    self?.reloadDictationHotkey()
                }
            },
            onFieldDictationRequested: { [weak self] rawTranscription, completion in
                guard let self else {
                    completion(nil)
                    return
                }
                Task { @MainActor in
                    await self.beginFieldCapture(
                        rawTranscription: rawTranscription,
                        onResult: completion
                    )
                }
            },
            onFieldDictationStopRequested: { [weak self] in
                Task { @MainActor in
                    await self?.stopDictationAndTranscribe()
                }
            },
            onFieldDictationCancelRequested: { [weak self] in
                Task { @MainActor in
                    await self?.cancelDictation()
                }
            },
            onHistoryAudioPlayRequested: { [weak self] entryID, url in
                try self?.playHistoryAudio(entryID: entryID, url: url)
            },
            onHistoryAudioStopRequested: { [weak self] in
                self?.stopHistoryAudio()
            },
            playingHistoryEntryID: { [weak self] in
                self?.playback.session?.entryID
            }
        )
    }

    /// Libera o Parakeet da RAM quando o ditado não vai mais usá-lo.
    ///
    /// Ele permanece quente entre ditagens; ao ligar o modo teste, voltar para a
    /// API ou excluir o modelo, soltamos a referência.
    func releaseLocalModelResources() {
        guard let composite = transcriptionService as? CompositeTranscriptionService else { return }
        composite.unloadCachedLocalModel()
    }

    var audioLevel: Float {
        audioRecorder.audioLevel
    }

    /// Relê o status de Acessibilidade (útil depois de o usuário autorizar nos Ajustes).
    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = accessibilityService.isTrusted()
    }

    /// Encerra e reabre o app para o macOS reavaliar a confiança de Acessibilidade.
    func relaunchForAccessibility() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
        }
    }

    /// Solicita a permissão de Acessibilidade (diálogo nativo + Ajustes).
    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        let granted = accessibilityService.requestAccess()
        isAccessibilityTrusted = granted
        if !granted {
            AccessibilityPermission.openSystemSettings()
        }
        return granted
    }

    /// Liga o monitoramento global do atalho de ditado.
    func startHotkeyMonitoring() {
        guard !isHotkeyMonitoringEnabled else { return }

        hotkeyService.onPressed = { [weak self] in
            Task { @MainActor in
                await self?.handleHotkeyPressed()
            }
        }

        hotkeyService.onReleased = { [weak self] in
            // Release não finaliza — permite pause/continua no HUD.
            self?.hotkeyService.resetHoldState()
        }

        let hotkey = settings.dictationHotkey
        hotkeyService.start(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
        isHotkeyMonitoringEnabled = true
    }

    func stopHotkeyMonitoring() {
        hotkeyService.stop()
        isHotkeyMonitoringEnabled = false
    }

    /// Liga o atalho global da captura de tela.
    func startCaptureHotkeyMonitoring() {
        captureHotkeyService.onTriggered = { [weak self] in
            Task { @MainActor in
                self?.captureCoordinator.beginCapture()
            }
        }
        captureHotkeyService.onWindowModeRequested = { [weak self] in
            Task { @MainActor in
                self?.captureCoordinator.requestWindowMode()
            }
        }
        let hotkey = settings.captureHotkey
        captureHotkeyService.start(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
    }

    /// Reaplica o atalho de captura salvo nas configurações.
    func reloadCaptureHotkey() {
        let hotkey = settings.captureHotkey
        captureHotkeyService.rebind(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
    }

    /// Começa a observar a área de transferência, se o usuário quiser.
    func startClipboardMonitoringIfEnabled() {
        if settings.isClipboardHistoryEnabled {
            clipboardMonitor.start()
        } else {
            clipboardMonitor.stop()
        }
    }

    /// Reaplica o atalho salvo (após o usuário alterar em Configurações).
    func reloadDictationHotkey() {
        let hotkey = settings.dictationHotkey
        if isHotkeyMonitoringEnabled {
            hotkeyService.rebind(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
        } else {
            startHotkeyMonitoring()
        }
    }

    /// Pausa o atalho global enquanto a UI captura um novo combo.
    func pauseHotkeyMonitoringForCapture() {
        stopHotkeyMonitoring()
    }

    /// Atalho: inicia se idle; se já gravando/pausado, envia para transcrição.
    func handleHotkeyPressed() async {
        switch recordingState {
        case .recording, .paused:
            guard !isMicrophoneOnlyTest else { return }
            await finishDictationPipeline()
        case .idle, .error, .success, .awaitingManualInsert:
            await beginDictationSession()
        case .transcribing, .inserting:
            break
        }
    }

    /// Copia a ditagem pendente (só sob pedido do usuário).
    func copyPendingDictation() {
        guard let text = pendingDictationText, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Fecha a barra de resgate sem copiar.
    func dismissPendingDictation() {
        pendingDictationText = nil
        if recordingState == .awaitingManualInsert {
            recordingState = .idle
        } else {
            overlayController.sync(with: self)
        }
    }

    /// Inicia sessão de ditado (continua até pause/stop ou novo ⇧ Tab).
    func beginDictationSession() async {
        guard canStartRecording else { return }

        // A barra é uma só: gravar interrompe o que estiver tocando.
        playback.stop()
        isMicrophoneOnlyTest = false
        successResetTask?.cancel()
        permissionDeniedMessage = nil
        lastHotkeyResultMessage = nil
        lastInsertionMessage = nil
        lastTranscriptionText = nil
        pendingDictationText = nil
        displayedAudioLevel = 0
        recordingDurationText = "0:00"
        accumulatedRecordingDuration = 0
        LiveAudioMeter.shared.reset()
        refreshAccessibilityStatus()
        settings.refreshAPIKeyStatus()

        if let gateError = dictationReadinessError() {
            failWithPermission(gateError)
            return
        }

        // Enquanto o usuário fala, o Parakeet já carrega/especializa o ANE.
        warmLocalModelsIfNeeded()

        do {
            captureFocusBeforeRecordingBestEffort()
            try await audioRecorder.startRecording()
            recordingStartedAt = Date()
            recordingState = .recording
            lastRecordingURL = nil
            lastRecordingByteCount = nil
            startLevelPolling()
            startDurationTicker()
        } catch let error as VoiceInputError where error == .microphonePermissionDenied {
            failWithPermission(error)
        } catch let error as VoiceInputError {
            failRecording(message: error.localizedDescription)
        } catch {
            failRecording(message: VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Grava e devolve o texto a um campo do próprio app, sem inserir em lugar
    /// nenhum.
    ///
    /// Reaproveita o pipeline inteiro do ditado — barra flutuante, cancelar,
    /// pausar —, trocando só o destino. Não captura foco: o texto vai direto
    /// para o estado da view, o que também evita chamar a API de
    /// acessibilidade no próprio processo.
    ///
    /// - Parameter rawTranscription: `true` pede o texto sem substituição de
    ///   palavras, para o campo que guarda justamente a grafia errada.
    func beginFieldCapture(
        rawTranscription: Bool,
        onResult: @escaping (String?) -> Void
    ) async {
        guard canStartRecording else {
            onResult(nil)
            return
        }

        fieldCaptureHandler = onResult
        isCapturingForField = true
        appliesWordReplacementsInCapture = !rawTranscription

        isMicrophoneOnlyTest = false
        successResetTask?.cancel()
        permissionDeniedMessage = nil
        lastHotkeyResultMessage = nil
        lastInsertionMessage = nil
        lastTranscriptionText = nil
        pendingDictationText = nil
        displayedAudioLevel = 0
        recordingDurationText = "0:00"
        accumulatedRecordingDuration = 0
        LiveAudioMeter.shared.reset()
        settings.refreshAPIKeyStatus()

        if let gateError = dictationReadinessError() {
            finishFieldCapture(with: nil)
            failWithPermission(gateError)
            return
        }

        warmLocalModelsIfNeeded()

        do {
            try await audioRecorder.startRecording()
            recordingStartedAt = Date()
            recordingState = .recording
            lastRecordingURL = nil
            lastRecordingByteCount = nil
            startLevelPolling()
            startDurationTicker()
        } catch let error as VoiceInputError where error == .microphonePermissionDenied {
            finishFieldCapture(with: nil)
            failWithPermission(error)
        } catch let error as VoiceInputError {
            finishFieldCapture(with: nil)
            failRecording(message: error.localizedDescription)
        } catch {
            finishFieldCapture(with: nil)
            failRecording(message: VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Encerra a captura avisando quem pediu — inclusive quando não houve texto.
    private func finishFieldCapture(with text: String?) {
        let handler = fieldCaptureHandler
        clearFieldCapture()
        handler?(text)
    }

    private func clearFieldCapture() {
        fieldCaptureHandler = nil
        isCapturingForField = false
        appliesWordReplacementsInCapture = true
    }

    /// Pausa a captura (mesmo arquivo; dá para continuar depois).
    func pauseDictation() async {
        guard recordingState == .recording, !isMicrophoneOnlyTest else { return }
        do {
            try await audioRecorder.pauseRecording()
            if let startedAt = recordingStartedAt {
                accumulatedRecordingDuration += Date().timeIntervalSince(startedAt)
            }
            recordingStartedAt = nil
            recordingState = .paused
            stopLevelPolling()
            LiveAudioMeter.shared.reset()
            displayedAudioLevel = 0
            recordingDurationText = Self.formatDuration(accumulatedRecordingDuration)
        } catch {
            failRecording(message: (error as? VoiceInputError)?.localizedDescription
                ?? VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Retoma a captura após pause.
    func resumeDictation() async {
        guard recordingState == .paused, !isMicrophoneOnlyTest else { return }
        do {
            try await audioRecorder.resumeRecording()
            recordingStartedAt = Date()
            recordingState = .recording
            startLevelPolling()
            startDurationTicker()
        } catch {
            failRecording(message: (error as? VoiceInputError)?.localizedDescription
                ?? VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Descarta a gravação em andamento (botão ✕ do HUD).
    ///
    /// Diferente do encerramento normal: não transcreve, não insere e não grava
    /// no histórico. O usuário pediu para essa ditagem deixar de existir, então
    /// o áudio é apagado mesmo com "manter gravações" ligado — a opção fala
    /// sobre ditagens concluídas, não sobre uma que foi cancelada.
    func cancelDictation() async {
        guard recordingState == .recording || recordingState == .paused else { return }
        guard !isMicrophoneOnlyTest else { return }

        stopLevelPolling()
        stopDurationTicker()
        recordingStartedAt = nil
        accumulatedRecordingDuration = 0

        // Encerra a captura só para liberar microfone e writer; o PCM devolvido
        // é descartado junto com o resto.
        let capture = try? await audioRecorder.stopCapture()
        hotkeyService.resetHoldState()
        capturedFocusedElement = nil
        finishFieldCapture(with: nil)

        if let audioURL = capture?.fileURL {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.audioRecorder.finalizedRecording()
                try? self.audioRecorder.deleteRecording(at: audioURL)
                if self.lastRecordingURL == audioURL {
                    self.lastRecordingURL = nil
                }
            }
        }

        lastRecordingURL = nil
        lastRecordingByteCount = nil
        lastTranscriptionText = nil
        lastInsertionMessage = nil
        lastHotkeyResultMessage = "Gravação descartada."
        displayedAudioLevel = 0
        recordingDurationText = "0:00"
        LiveAudioMeter.shared.reset()
        recordingState = .idle

        logger.notice("Ditagem cancelada pelo usuário; nada foi transcrito nem salvo.")
    }

    /// Encerra e envia para transcrição (botão ■ do HUD).
    func stopDictationAndTranscribe() async {
        guard recordingState == .recording || recordingState == .paused else { return }
        guard !isMicrophoneOnlyTest else { return }
        await finishDictationPipeline()
    }

    /// Inicia gravação de teste do microfone (menu) — **nunca** chama OpenAI.
    func startTestRecording() async {
        guard canStartRecording else { return }
        isMicrophoneOnlyTest = true
        successResetTask?.cancel()
        permissionDeniedMessage = nil
        lastHotkeyResultMessage = nil
        lastInsertionMessage = nil
        displayedAudioLevel = 0
        recordingDurationText = "0:00"
        accumulatedRecordingDuration = 0
        LiveAudioMeter.shared.reset()
        refreshAccessibilityStatus()

        do {
            try await audioRecorder.startRecording()
            recordingStartedAt = Date()
            recordingState = .recording
            lastRecordingURL = nil
            lastRecordingByteCount = nil
            startLevelPolling()
            startDurationTicker()
        } catch let error as VoiceInputError where error == .microphonePermissionDenied {
            isMicrophoneOnlyTest = false
            failWithPermission(error)
        } catch let error as VoiceInputError {
            isMicrophoneOnlyTest = false
            failRecording(message: error.localizedDescription)
        } catch {
            isMicrophoneOnlyTest = false
            failRecording(message: VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Encerra teste de microfone: só valida arquivo local, sem OpenAI e sem inserção.
    func stopTestRecording(deleteAfterValidation: Bool = false) async -> String {
        guard (recordingState == .recording || recordingState == .paused), isMicrophoneOnlyTest else {
            return VoiceInputError.recordingNotInProgress.localizedDescription
        }

        stopLevelPolling()
        stopDurationTicker()
        let message = await stopRecordingInternal(deleteAfterValidation: deleteAfterValidation)
        lastHotkeyResultMessage = message
        isMicrophoneOnlyTest = false
        hotkeyService.resetHoldState()

        if recordingState != .error {
            lastInsertionMessage = "Teste de microfone OK (sem OpenAI)."
            recordingState = .idle
        } else {
            scheduleReturnToIdle(afterMilliseconds: 2_000)
        }

        return message
    }

    /// Insere texto local de teste (sem OpenAI).
    func insertTestTextNow() async -> String {
        refreshAccessibilityStatus()
        guard isAccessibilityTrusted else {
            permissionDeniedMessage = VoiceInputError.accessibilityPermissionDenied.localizedDescription
            recordingState = .error
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return permissionDeniedMessage ?? ""
        }

        recordingState = .idle
        do {
            try await textInsertionService.insert(text: Self.localInsertionTestText)
            let method = textInsertionService.lastMethod?.rawValue ?? "desconhecido"
            lastInsertionMessage = "Texto local inserido via \(method)."
            recordingState = .idle
            return lastInsertionMessage ?? ""
        } catch let error as VoiceInputError {
            recordingState = .error
            lastInsertionMessage = error.localizedDescription
            permissionDeniedMessage = error == .accessibilityPermissionDenied ? error.localizedDescription : nil
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return error.localizedDescription
        } catch {
            recordingState = .error
            lastInsertionMessage = VoiceInputError.textInsertionFailed.localizedDescription
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return lastInsertionMessage ?? ""
        }
    }

    func resetErrorState() {
        if recordingState == .error {
            recordingState = .idle
        }
        permissionDeniedMessage = nil
    }

    /// Abre no Finder a pasta das gravações, já selecionando a mais recente.
    func openRecordingsFolder() {
        if let lastRecordingURL, FileManager.default.fileExists(atPath: lastRecordingURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
            return
        }
        NSWorkspace.shared.open(RecordingStorage.directoryURL)
    }

    // MARK: - Privado

    /// Single-flight: só inicia se estiver livre.
    private var canStartRecording: Bool {
        switch recordingState {
        case .idle, .error, .success, .awaitingManualInsert:
            return true
        case .recording, .paused, .transcribing, .inserting:
            return false
        }
    }

    private var currentActiveDuration: TimeInterval {
        var total = accumulatedRecordingDuration
        if recordingState == .recording, let startedAt = recordingStartedAt {
            total += Date().timeIntervalSince(startedAt)
        }
        return total
    }

    private func finishDictationPipeline() async {
        var trace = LatencyTrace("ditado")
        stopLevelPolling()
        stopDurationTicker()

        // O destino sai do estado logo no início: são muitos retornos
        // antecipados aqui (silêncio, erro de gate, falha de ASR), e qualquer um
        // que esquecesse de limpar deixaria a próxima ditagem normal ser
        // desviada para um campo que nem está mais na tela.
        let fieldHandler = fieldCaptureHandler
        let applyReplacements = appliesWordReplacementsInCapture
        clearFieldCapture()

        // O campo precisa saber que acabou mesmo quando não veio texto, senão
        // fica preso em "gravando". `defer` cobre os retornos antecipados sem
        // depender de lembrar de cada um.
        var deliveredToField = false
        defer {
            if let fieldHandler, !deliveredToField {
                fieldHandler(nil)
            }
        }

        if recordingState == .recording, let startedAt = recordingStartedAt {
            accumulatedRecordingDuration += Date().timeIntervalSince(startedAt)
            recordingStartedAt = nil
        }

        let capture: StoppedCapture
        do {
            capture = try await audioRecorder.stopCapture()
        } catch {
            hotkeyService.resetHoldState()
            recordingState = .error
            lastHotkeyResultMessage = (error as? VoiceInputError)?.localizedDescription
                ?? VoiceInputError.recordingFailed.localizedDescription
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return
        }
        trace.mark("captura")

        let audioURL = capture.fileURL
        lastRecordingURL = audioURL
        lastHotkeyResultMessage = String(format: "Áudio capturado: %.1f s.", capture.durationSeconds)
        hotkeyService.resetHoldState()
        // O `.m4a` ainda está sendo escrito; o diagnóstico chega quando terminar.
        observeRecordingFinalization()

        guard !capture.pcmSamples.isEmpty else {
            recordingState = .error
            lastHotkeyResultMessage = VoiceInputError.recordingFailed.localizedDescription
            discardRecordingIfNeeded(audioURL)
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return
        }

        // Silêncio: decidido pela energia acumulada na captura, sem revarrer o
        // PCM e sem pagar uma inferência inteira para não inserir nada.
        //
        // Só no caminho local: os limiares foram calibrados contra alucinação
        // do modelo local, e o backend OpenAI nunca foi filtrado aqui.
        if !transcriptionNeedsAudioFile,
           !SpeechPresenceAnalyzer.hasSpeechEnergy(stats: capture.speechStats) {
            logger.notice("Ditagem sem fala detectada; nada foi inserido.")
            lastInsertionMessage = VoiceInputError.noSpeechDetected.localizedDescription
            recordingState = .idle
            discardRecordingIfNeeded(audioURL)
            scheduleReturnToIdle(afterMilliseconds: 1_400)
            return
        }

        // Gate novamente (modo teste, API ou modelo local). A releitura da chave
        // é uma consulta ao Keychain (IPC com o securityd) e só interessa ao
        // gate da OpenAI — no caminho local era latência pura.
        if transcriptionNeedsAudioFile {
            settings.refreshAPIKeyStatus()
        }
        trace.mark("chaves")
        if let gateError = dictationReadinessError() {
            recordingState = .error
            permissionDeniedMessage = gateError.localizedDescription
            discardRecordingIfNeeded(audioURL)
            scheduleReturnToIdle(afterMilliseconds: 2_500)
            return
        }

        recordingState = .transcribing
        trace.mark("gates")

        // Só o backend OpenAI lê o arquivo; aí sim vale esperar o encoder AAC.
        if transcriptionNeedsAudioFile {
            do {
                _ = try await audioRecorder.finalizedRecording()
            } catch {
                recordingState = .error
                lastInsertionMessage = (error as? VoiceInputError)?.localizedDescription
                    ?? VoiceInputError.recordingFailed.localizedDescription
                scheduleReturnToIdle(afterMilliseconds: 2_500)
                return
            }
            trace.mark("arquivo")
        }

        let transcribed: String
        do {
            transcribed = try await transcriptionService.transcribe(
                audioURL: audioURL,
                pcmSamples: capture.pcmSamples,
                applyWordReplacements: applyReplacements
            )
            trace.mark("asr")
            lastTranscriptionText = transcribed
        } catch let error as VoiceInputError where error == .noSpeechDetected {
            // Silêncio: não insere, não abre diálogo de resgate — só avisa de leve.
            logger.notice("Ditagem sem fala detectada; nada foi inserido.")
            lastInsertionMessage = error.localizedDescription
            recordingState = .idle
            discardRecordingIfNeeded(audioURL)
            scheduleReturnToIdle(afterMilliseconds: 1_400)
            return
        } catch let error as VoiceInputError {
            recordingState = .error
            lastInsertionMessage = error.localizedDescription
            if error == .missingAPIKey || error == .localModelMissing {
                permissionDeniedMessage = error.localizedDescription
            }
            discardRecordingIfNeeded(audioURL)
            scheduleReturnToIdle(afterMilliseconds: 2_500)
            return
        } catch {
            recordingState = .error
            lastInsertionMessage = VoiceInputError.transcriptionFailed.localizedDescription
            discardRecordingIfNeeded(audioURL)
            scheduleReturnToIdle(afterMilliseconds: 2_500)
            return
        }

        // Captura para um campo do app: entrega a quem pediu e para por aqui.
        // Não insere em lugar nenhum, não vai para o histórico (é vocabulário
        // sendo cadastrado, não uma ditagem) e o áudio é sempre descartado.
        if let handler = fieldHandler {
            recordingState = .idle
            lastInsertionMessage = nil
            deliveredToField = true
            handler(transcribed)
            trace.summary()
            deleteRecording(audioURL)
            return
        }

        await insertTranscribedText(transcribed)
        trace.mark("inserção")
        trace.summary()

        // Depois da inserção: o encode JSON do histórico cresce a cada ditagem e
        // não pode ficar entre a transcrição pronta e o texto na tela.
        //
        // O áudio só é ligado à entrada quando "manter gravações" está ligado —
        // caso contrário o arquivo é apagado logo abaixo e o link nasceria morto.
        recordTranscriptionHistoryIfNeeded(
            transcribed,
            durationSeconds: capture.durationSeconds,
            audioFileName: settings.keepRecordingsAfterTranscription ? audioURL.lastPathComponent : nil
        )
        discardRecordingIfNeeded(audioURL)
    }

    /// `true` quando a transcrição vai ler o `.m4a` em vez do PCM em memória.
    private var transcriptionNeedsAudioFile: Bool {
        guard !settings.isTestModeEnabled else { return false }
        return settings.transcriptionBackend != "local"
    }

    /// Publica o diagnóstico da captura quando o `.m4a` termina de ser escrito.
    private func observeRecordingFinalization() {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.audioRecorder.finalizedRecording()
            let diagnostics = self.audioRecorder.lastDiagnostics
            self.lastCaptureDiagnostics = diagnostics
            self.lastRecordingByteCount = diagnostics.byteCount
        }
    }

    /// Apaga a gravação sempre, independente de "manter gravações".
    ///
    /// A opção fala sobre ditagens; capturar uma palavra para a lista de
    /// substituições não é ditagem, e guardar esses trechos só sujaria a pasta.
    private func deleteRecording(_ audioURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.audioRecorder.finalizedRecording()
            try? self.audioRecorder.deleteRecording(at: audioURL)
            if self.lastRecordingURL == audioURL {
                self.lastRecordingURL = nil
            }
        }
    }

    /// Apaga a gravação quando o usuário não pediu para mantê-la.
    ///
    /// Espera o writer fechar o arquivo: apagar no meio da escrita deixaria o
    /// `AVAssetWriter` falhando em background.
    private func discardRecordingIfNeeded(_ audioURL: URL) {
        guard !settings.keepRecordingsAfterTranscription else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.audioRecorder.finalizedRecording()
            try? self.audioRecorder.deleteRecording(at: audioURL)
            if self.lastRecordingURL == audioURL {
                self.lastRecordingURL = nil
            }
        }
    }

    /// Salva no histórico local quando a captura está ligada e não é modo teste.
    private func recordTranscriptionHistoryIfNeeded(
        _ text: String,
        durationSeconds: Double,
        audioFileName: String?
    ) {
        guard settings.isTranscriptionHistoryEnabled else { return }
        guard !settings.isTestModeEnabled else { return }
        let duration = accumulatedRecordingDuration > 0
            ? accumulatedRecordingDuration
            : durationSeconds
        historyStore.append(
            text: text,
            durationSeconds: duration,
            audioFileName: audioFileName
        )
    }

    private func insertTranscribedText(_ text: String) async {
        // Esconde o HUD antes de digitar (Electron/Cursor).
        recordingState = .idle

        do {
            if let captured = capturedFocusedElement {
                try await textInsertionService.insert(text: text, into: captured)
            } else {
                try await textInsertionService.insert(text: text)
            }
            let method = textInsertionService.lastMethod?.rawValue ?? "desconhecido"
            lastInsertionMessage = "Inserido via \(method)."
            recordingState = .idle
        } catch let error as VoiceInputError where error == .accessibilityPermissionDenied {
            recordingState = .error
            lastInsertionMessage = error.localizedDescription
            permissionDeniedMessage = error.localizedDescription
            scheduleReturnToIdle(afterMilliseconds: 2_000)
        } catch let error as VoiceInputError where error == .noFocusedElement {
            logger.notice("Nenhum alvo de inserção; oferecendo o texto ao usuário.")
            presentInsertionRescue(for: text, reason: .noFocusedField)
        } catch {
            // Qualquer outra falha: o texto não pode se perder.
            logger.notice("Inserção falhou (\(String(describing: error), privacy: .public)); oferecendo o texto ao usuário.")
            presentInsertionRescue(for: text, reason: .insertionRefused)
        }

        capturedFocusedElement = nil
    }

    /// Mostra a ditagem na barra flutuante quando a inserção automática falhou.
    ///
    /// Não escreve na área de transferência: sobrescrever o que o usuário
    /// copiou seria perda de dado. A cópia só acontece se ele clicar em "Copiar".
    private func presentInsertionRescue(for text: String, reason: InsertionRescueReason) {
        lastInsertionMessage = reason.statusMessage
        permissionDeniedMessage = nil
        pendingDictationText = text
        recordingState = .awaitingManualInsert
    }

    /// Pré-condições do ditado conforme backend (teste ignora tudo).
    private func dictationReadinessError() -> VoiceInputError? {
        if settings.isTestModeEnabled { return nil }
        if settings.transcriptionBackend == "local" {
            guard LocalParakeetModelStore.shared.isDownloaded else {
                return .localModelMissing
            }
            return nil
        }
        if !settings.hasAPIKey {
            return .missingAPIKey
        }
        return nil
    }

    private func captureFocusBeforeRecordingBestEffort() {
        refreshAccessibilityStatus()
        guard isAccessibilityTrusted else {
            capturedFocusedElement = nil
            lastFocusedElementSummary = "sem Acessibilidade"
            return
        }

        do {
            let focused = try accessibilityService.focusedElement()
            capturedFocusedElement = focused
            lastFocusedElementSummary = focused.summary
        } catch {
            capturedFocusedElement = nil
            lastFocusedElementSummary = "foco indisponível"
        }
    }

    private func stopRecordingInternal(deleteAfterValidation: Bool) async -> String {
        do {
            let url = try await audioRecorder.stopRecording()
            let diagnostics = audioRecorder.lastDiagnostics

            lastRecordingURL = url
            lastRecordingByteCount = diagnostics.byteCount
            lastCaptureDiagnostics = diagnostics

            let message = "Áudio salvo:\n\(diagnostics.summary)"

            if deleteAfterValidation {
                try audioRecorder.deleteRecording(at: url)
                lastRecordingURL = nil
            }

            return message
        } catch {
            let diagnostics = audioRecorder.lastDiagnostics
            lastCaptureDiagnostics = diagnostics
            lastRecordingURL = diagnostics.fileURL
            lastRecordingByteCount = diagnostics.byteCount
            recordingState = .error

            let description = (error as? VoiceInputError)?.localizedDescription
                ?? VoiceInputError.recordingFailed.localizedDescription
            return "\(description)\n\(diagnostics.summary)"
        }
    }

    private func failWithPermission(_ error: VoiceInputError) {
        stopLevelPolling()
        stopDurationTicker()
        hotkeyService.resetHoldState()
        capturedFocusedElement = nil
        isMicrophoneOnlyTest = false
        recordingState = .error
        permissionDeniedMessage = error.localizedDescription
        scheduleReturnToIdle(afterMilliseconds: 2_500)
    }

    private func failRecording(message: String) {
        stopLevelPolling()
        stopDurationTicker()
        hotkeyService.resetHoldState()
        capturedFocusedElement = nil
        isMicrophoneOnlyTest = false
        recordingState = .error
        permissionDeniedMessage = message
        scheduleReturnToIdle(afterMilliseconds: 2_000)
    }

    private func startLevelPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = Task { @MainActor in
            while !Task.isCancelled && recordingState == .recording {
                let level: Float
                if let recorder = audioRecorder as? AudioRecorder {
                    level = recorder.pollMeterLevel()
                } else {
                    level = audioRecorder.audioLevel
                    LiveAudioMeter.shared.setLevel(level)
                }
                displayedAudioLevel = level
                try? await Task.sleep(for: .milliseconds(33))
            }
            displayedAudioLevel = 0
        }
    }

    private func stopLevelPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = nil
        displayedAudioLevel = 0
    }

    private func startDurationTicker() {
        durationTask?.cancel()
        durationTask = Task { @MainActor in
            while !Task.isCancelled && (recordingState == .recording || recordingState == .paused) {
                recordingDurationText = Self.formatDuration(currentActiveDuration)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func stopDurationTicker() {
        durationTask?.cancel()
        durationTask = nil
        recordingDurationText = Self.formatDuration(currentActiveDuration)
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func scheduleReturnToIdle(afterMilliseconds: UInt64) {
        successResetTask?.cancel()
        successResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(afterMilliseconds))
            guard !Task.isCancelled else { return }
            if recordingState == .success || recordingState == .error {
                recordingState = .idle
                hotkeyService.resetHoldState()
            }
        }
    }
}
