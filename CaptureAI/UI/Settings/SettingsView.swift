import AppKit
import SwiftUI

/// Abas da janela de configurações.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case models
    case transcription
    case clipboard
    case history
    case recordings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Geral"
        case .appearance: return "Aparência"
        case .models: return "Modelos"
        case .transcription: return "Transcrição"
        case .clipboard: return "Área de Transferência"
        case .history: return "Histórico"
        case .recordings: return "Gravações"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .appearance: return "paintpalette.fill"
        case .models: return "sparkles"
        case .transcription: return "waveform"
        case .clipboard: return "doc.on.clipboard"
        case .history: return "clock.arrow.circlepath"
        case .recordings: return "folder.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Início automático, atalho e permissões do macOS."
        case .appearance: return "Tema da interface e visual da barra de gravação."
        case .models: return "API OpenAI e modelo local."
        case .transcription: return "Idioma do ditado e substituição de palavras."
        case .clipboard: return "Textos copiados e capturas de tela."
        case .history: return "Transcrições salvas neste Mac."
        case .recordings: return "O que fazer com os arquivos de áudio."
        }
    }
}

/// Janela de configurações: abas na lateral, conteúdo à direita.
struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme

    /// Mora no view model para quem abre a janela poder escolher a aba —
    /// o menu da barra de status abre direto no Histórico.
    private var selectedTab: SettingsTab { viewModel.selectedTab }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            divider
            content
                .overlay(alignment: .bottom) {
                    PanelToastView(viewModel: viewModel)
                }
        }
        .background(SettingsBackground())
        .frame(minWidth: 860, minHeight: 620)
        .preferredColorScheme(viewModel.preferredColorScheme)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshLocalModelDiskState()
        }
        .onDisappear {
            viewModel.cancelHotkeyCapture()
        }
        .sheet(isPresented: $viewModel.isShowingWordReplacements) {
            WordReplacementsModal(viewModel: viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.refreshLocalModelDiskState()
        }
    }

    // MARK: - Lateral

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // As mesmas barras da barra de status: o app tem uma marca só,
                // e o SF Symbol genérico não era ela.
                Image(nsImage: MenuBarWaveformIcon.image(pointSize: 20))
                    .renderingMode(.template)
                    .foregroundStyle(SettingsTheme.accent)
                    .frame(width: 20, height: 20)

                Text("CaptureAI")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.top, 28)
            .padding(.bottom, 22)

            ForEach(SettingsTab.allCases) { tab in
                sidebarRow(for: tab)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 208)
    }

    private func sidebarRow(for tab: SettingsTab) -> some View {
        let isSelected = tab == selectedTab

        return Button {
            viewModel.selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(
                        isSelected
                            ? SettingsTheme.primaryLabel(colorScheme)
                            : SettingsTheme.tertiaryLabel(colorScheme)
                    )

                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? SettingsTheme.primaryLabel(colorScheme)
                            : SettingsTheme.secondaryLabel(colorScheme).opacity(1.2)
                    )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SettingsTheme.sidebarSelection(colorScheme))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(SettingsTheme.divider(colorScheme))
            .frame(width: 1)
            .ignoresSafeArea()
    }

    // MARK: - Conteúdo

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedTab.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))

                    Text(selectedTab.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                }
                .padding(.bottom, 2)

                switch selectedTab {
                case .general:
                    generalTab
                case .appearance:
                    appearanceTab
                case .models:
                    modelsTab
                case .transcription:
                    transcriptionTab
                case .clipboard:
                    ClipboardSettingsView(viewModel: viewModel)
                case .history:
                    HistorySettingsView(viewModel: viewModel)
                case .recordings:
                    recordingsTab
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Aba Geral

    private var generalTab: some View {
        VStack(spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsRow(
                        title: "Abrir ao iniciar o Mac",
                        description: "Coloca o CaptureAI nos itens de início do sistema."
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.opensAtLogin },
                                set: { viewModel.setOpensAtLogin($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SettingsTheme.accent)
                    }

                    if let hint = viewModel.launchAtLoginHint {
                        Text(hint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(red: 1.00, green: 0.70, blue: 0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard(
                title: "Atalho de ditado",
                subtitle: viewModel.isCapturingHotkey
                    ? (viewModel.hotkeyCaptureHint ?? "Pressione o novo atalho…")
                    : viewModel.dictationHotkey.holdInstruction
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        if viewModel.isCapturingHotkey {
                            Text("Aguardando teclas…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SettingsTheme.accent)
                        } else {
                            ForEach(Array(viewModel.dictationHotkey.keyParts.enumerated()), id: \.element.id) { index, part in
                                if index > 0 {
                                    Text("+")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
                                }
                                HotkeyKeyCap(symbol: part.symbol, title: part.title)
                            }
                        }

                        Spacer(minLength: 8)

                        if viewModel.isCapturingHotkey {
                            Button("Cancelar") {
                                viewModel.cancelHotkeyCapture()
                            }
                            .buttonStyle(GhostButtonStyle())
                        } else {
                            Button("Alterar") {
                                viewModel.beginHotkeyCapture()
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }

                    if !viewModel.isCapturingHotkey, let hint = viewModel.hotkeyCaptureHint {
                        Text(hint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(red: 0.40, green: 0.90, blue: 0.62))
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                            .task(id: hint) {
                                try? await Task.sleep(for: .seconds(5))
                                guard !Task.isCancelled else { return }
                                if viewModel.hotkeyCaptureHint == hint {
                                    viewModel.clearHotkeyCaptureHint()
                                }
                            }
                    }
                }
            }

            SettingsCard(
                title: "Permissões do macOS",
                subtitle: "As duas são necessárias: gravar o áudio e escrever no app em foco."
            ) {
                VStack(spacing: 14) {
                    SettingsRow(
                        title: "Microfone",
                        description: "Captura o áudio do ditado.",
                        icon: PermissionIndicator.symbol(isGranted: viewModel.isMicrophoneAuthorized),
                        iconColor: PermissionIndicator.color(isGranted: viewModel.isMicrophoneAuthorized)
                    ) {
                        Button("Ajustes") {
                            viewModel.openMicrophoneSettings()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Acessibilidade",
                        description: "Insere o texto transcrito no campo em foco.",
                        icon: PermissionIndicator.symbol(isGranted: viewModel.isAccessibilityTrusted),
                        iconColor: PermissionIndicator.color(isGranted: viewModel.isAccessibilityTrusted)
                    ) {
                        Button(viewModel.isAccessibilityTrusted ? "Ajustes" : "Autorizar") {
                            viewModel.handleAccessibilityAction()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - Aba Aparência

    private var appearanceTab: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Tema",
                subtitle: "Aparência da janela de configurações: sistema, claro ou escuro."
            ) {
                AppearanceThemePicker(
                    selection: Binding(
                        get: { viewModel.appearanceTheme },
                        set: { viewModel.appearanceTheme = $0 }
                    )
                )
            }

            SettingsCard(
                title: "Barra de gravação",
                subtitle: "Visual da barra flutuante com o waveform durante o ditado."
            ) {
                RecordingHUDStylePicker(
                    selection: Binding(
                        get: { viewModel.recordingHUDStyle },
                        set: { viewModel.recordingHUDStyle = $0 }
                    )
                )
            }
        }
    }

    // MARK: - Aba Modelos

    private var modelsTab: some View {
        VStack(spacing: 16) {
            modelsPanePicker

            switch viewModel.selectedModelsPane {
            case .api:
                apiPane
            case .local:
                LocalModelsSettingsView(viewModel: viewModel)
            }
        }
    }

    private var modelsPanePicker: some View {
        HStack(spacing: 8) {
            ForEach(ModelsPane.allCases) { pane in
                let isSelected = viewModel.selectedModelsPane == pane
                Button {
                    viewModel.selectedModelsPane = pane
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(pane.title)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary.opacity(isSelected ? 0.95 : 0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(SettingsTheme.sidebarSelection(colorScheme))
                                .overlay {
                                    Capsule().strokeBorder(SettingsTheme.cardStroke(colorScheme), lineWidth: SettingsTheme.hairline)
                                }
                        } else {
                            Capsule()
                                .fill(SettingsTheme.cardFill(colorScheme))
                                .overlay {
                                    Capsule().strokeBorder(SettingsTheme.divider(colorScheme), lineWidth: SettingsTheme.hairline)
                                }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var apiPane: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "API key",
                subtitle: "A chave fica só no Keychain deste Mac — não vai para o código nem para logs."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    SecureField("sk-…", text: $viewModel.apiKeyDraft)
                        .textFieldStyle(GlassFieldStyle())

                    HStack(spacing: 10) {
                        StatusPill(
                            text: viewModel.apiKeyStatusLabel,
                            isPositive: viewModel.hasAPIKey
                        )

                        Spacer(minLength: 0)

                        if viewModel.hasAPIKey {
                            Button("Remover") {
                                viewModel.removeAPIKey()
                            }
                            .buttonStyle(GhostButtonStyle())
                        }

                        Button("Salvar chave") {
                            viewModel.saveAPIKey()
                        }
                        .buttonStyle(GradientButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            viewModel.apiKeyDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    }

                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(
                                viewModel.didSucceedLastAction
                                    ? Color(red: 0.40, green: 0.90, blue: 0.62)
                                    : Color(red: 1.00, green: 0.45, blue: 0.45)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Fica aqui, e não na aba Transcrição: é o modelo **da API**, e só
            // faz sentido ao lado da chave que o habilita.
            SettingsCard(title: "Modelo") {
                SettingsRow(
                    title: viewModel.modelLabel,
                    description: "Modelo econômico, adequado a ditados curtos."
                ) {
                    EmptyView()
                }
            }

            SettingsCard(title: "Créditos") {
                VStack(spacing: 14) {
                    SettingsRow(
                        title: "Modo teste",
                        description: viewModel.isTestModeEnabled
                            ? "Ativo: o ditado usa texto mock e não gasta crédito."
                            : "Desligado: cada ⇧ Tab bem-sucedido envia áudio à OpenAI e consome crédito."
                    ) {
                        Toggle("", isOn: $viewModel.isTestModeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(SettingsTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Aba Transcrição

    private var transcriptionTab: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Idioma",
                subtitle: "Enviado à API, exceto em “Detectar automaticamente”, que omite o campo."
            ) {
                languageMenu
            }

            wordReplacementsCard
        }
    }

    private var wordReplacementsCard: some View {
        // Sem cabeçalho próprio: o título vive na própria linha, junto do total
        // e do botão. O modal já explica o que a lista faz.
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(
                    title: "Substituição de palavras",
                    description: viewModel.wordReplacementSummary
                ) {
                    Button("Abrir") {
                        viewModel.isShowingWordReplacements = true
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                // A lista só tem efeito no motor local; na API o áudio vai para
                // a OpenAI e não há como injetar vocabulário.
                if !viewModel.usesLocalTranscription {
                    Text("O ditado está usando a API da OpenAI. A lista vale apenas no modelo local.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(red: 1.00, green: 0.70, blue: 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                } else if viewModel.wordReplacementCount > 0, !viewModel.isCtcModelDownloaded {
                    // Sem o CTC a lista fica cadastrada e inerte — melhor dizer
                    // isso aqui do que deixar o usuário achar que está corrigindo.
                    Text("Falta o modelo da substituição de palavras, em Modelos → Local. Sem ele a lista fica guardada, mas não corrige nada.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(red: 1.00, green: 0.70, blue: 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = viewModel.wordReplacementImportMessage {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(red: 0.40, green: 0.90, blue: 0.62))
                        .transition(.opacity)
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled else { return }
                            viewModel.clearWordReplacementImportMessage()
                        }
                }
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(TranscriptionLanguageOption.allCases) { option in
                Button(option.displayName) {
                    viewModel.selectedLanguage = option
                }
            }
        } label: {
            HStack {
                Text(viewModel.selectedLanguage.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .fill(SettingsTheme.fieldFill(colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.fieldStroke(colorScheme), lineWidth: SettingsTheme.hairline)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: 360, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aba Gravações

    private var recordingsTab: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Arquivos de áudio") {
                VStack(spacing: 14) {
                    SettingsRow(
                        title: "Manter após transcrever",
                        description: "Guarda o áudio junto de cada ditagem do histórico, para ouvir depois. Excluir a ditagem apaga o áudio."
                    ) {
                        Toggle("", isOn: $viewModel.keepRecordingsAfterTranscription)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(SettingsTheme.accent)
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Pasta das gravações",
                        description: viewModel.recordingsFolderPath
                    ) {
                        Button("Abrir no Finder") {
                            viewModel.openRecordingsFolder()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel(settings: AppSettings()))
}
