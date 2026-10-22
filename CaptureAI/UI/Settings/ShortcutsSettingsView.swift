import SwiftUI

/// Aba Atalhos: todos os atalhos do app num lugar só.
///
/// Os dois globais (ditado e captura) são editáveis; os acordes e os do editor
/// de captura derivam deles ou são fixos, e aparecem como referência — quem
/// troca o Print Screen por outra tecla precisa ver que o W e o F seguem a
/// tecla nova.
struct ShortcutsSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            ShortcutCard(
                viewModel: viewModel,
                target: .dictation,
                icon: "waveform",
                title: "Ditado",
                description: "Segure para gravar e solte para transcrever. Apertar de novo com a gravação pausada envia o áudio.",
                keyParts: viewModel.dictationHotkey.keyParts,
                isDefault: viewModel.dictationHotkey == .default
            )

            ShortcutCard(
                viewModel: viewModel,
                target: .capture,
                icon: "viewfinder",
                title: "Captura de tela",
                description: "Solte para selecionar uma área. Sem a tecla Print Screen no teclado, troque por uma tecla de função ou uma combinação.",
                keyParts: viewModel.captureHotkey.keyParts,
                isDefault: viewModel.captureHotkey == .default
            ) {
                chords
            }

            editorReference
        }
    }

    // MARK: - Acordes

    /// O atalho de captura segurado mais W ou F.
    private var chords: some View {
        VStack(spacing: 8) {
            chordRow(key: "W", icon: "macwindow", title: "Capturar uma janela")
            chordRow(key: "F", icon: "rectangle.dashed", title: "Capturar a tela inteira")
        }
    }

    private func chordRow(key: String, icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsTheme.accent)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))

            Spacer(minLength: 8)

            Text("segure")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
            ShortcutKeys(parts: viewModel.captureHotkey.keyParts, size: .small)
            plus
            ShortcutKeyCap(symbol: nil, title: key, size: .small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsTheme.fieldFill(colorScheme).opacity(0.7))
        }
    }

    private var plus: some View {
        Text("+")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
    }

    // MARK: - Editor

    private struct EditorShortcut: Identifiable {
        let keys: [String]
        let title: String
        var id: String { title }
    }

    private let editorShortcuts: [EditorShortcut] = [
        .init(keys: ["W"], title: "Alternar modo janela"),
        .init(keys: ["F"], title: "Tela inteira"),
        .init(keys: ["⌘", "C"], title: "Copiar"),
        .init(keys: ["Return"], title: "Copiar"),
        .init(keys: ["⌘", "S"], title: "Salvar"),
        .init(keys: ["⌘", "Z"], title: "Desfazer"),
        .init(keys: ["Esc"], title: "Cancelar"),
    ]

    private var editorReference: some View {
        SettingsCard(
            title: "No editor de captura",
            subtitle: "Com a tela congelada, depois de apertar o atalho de captura."
        ) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(Array(editorShortcuts.enumerated()), id: \.offset) { _, shortcut in
                    HStack(spacing: 8) {
                        Text(shortcut.title)
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme).opacity(1.4))
                        Spacer(minLength: 6)
                        HStack(spacing: 3) {
                            ForEach(shortcut.keys, id: \.self) { key in
                                ShortcutKeyCap(symbol: nil, title: key, size: .small)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SettingsTheme.fieldFill(colorScheme).opacity(0.7))
                    }
                }
            }
        }
    }
}

// MARK: - Cartão de um atalho global

/// Um atalho editável: ícone, teclas atuais e os botões de gravar e restaurar.
private struct ShortcutCard<Extra: View>: View {
    @Bindable var viewModel: SettingsViewModel
    let target: HotkeyTarget
    let icon: String
    let title: String
    let description: String
    let keyParts: [HotkeyKeyPart]
    let isDefault: Bool
    @ViewBuilder var extra: Extra

    @Environment(\.colorScheme) private var colorScheme

    init(
        viewModel: SettingsViewModel,
        target: HotkeyTarget,
        icon: String,
        title: String,
        description: String,
        keyParts: [HotkeyKeyPart],
        isDefault: Bool,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.viewModel = viewModel
        self.target = target
        self.icon = icon
        self.title = title
        self.description = description
        self.keyParts = keyParts
        self.isDefault = isDefault
        self.extra = extra()
    }

    private var isRecording: Bool { viewModel.recordingHotkey == target }

    private var hint: String? {
        viewModel.hotkeyHintTarget == target ? viewModel.hotkeyCaptureHint : nil
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ShortcutGlyph(icon: icon, isActive: isRecording)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ShortcutRecorderField(
                    keyParts: keyParts,
                    isRecording: isRecording,
                    hint: isRecording ? hint : nil
                ) {
                    if isRecording {
                        viewModel.cancelHotkeyCapture()
                    } else {
                        viewModel.beginHotkeyCapture(target)
                    }
                }

                HStack(spacing: 8) {
                    if let hint, !isRecording {
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

                    Spacer(minLength: 8)

                    if !isDefault {
                        Button("Restaurar padrão") { viewModel.resetHotkey(target) }
                            .buttonStyle(GhostButtonStyle())
                    }
                    Button(isRecording ? "Cancelar" : "Alterar") {
                        if isRecording {
                            viewModel.cancelHotkeyCapture()
                        } else {
                            viewModel.beginHotkeyCapture(target)
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if !(extra is EmptyView) {
                    extra
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: isRecording)
        .animation(.easeOut(duration: 0.18), value: hint)
    }
}

/// Ícone do atalho num quadrado de vidro com brilho ciano.
private struct ShortcutGlyph: View {
    let icon: String
    let isActive: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(SettingsTheme.accent)
            .frame(width: 38, height: 38)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsTheme.accent.opacity(isActive ? 0.24 : 0.14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(SettingsTheme.accent.opacity(0.35), lineWidth: SettingsTheme.hairline)
            }
            .shadow(color: SettingsTheme.accent.opacity(isActive ? 0.45 : 0.18), radius: isActive ? 12 : 8)
    }
}

/// Faixa com as teclas do atalho; clicada, passa a escutar o novo atalho.
private struct ShortcutRecorderField: View {
    let keyParts: [HotkeyKeyPart]
    let isRecording: Bool
    let hint: String?
    let action: () -> Void

    @State private var pulse = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isRecording {
                    Circle()
                        .fill(SettingsTheme.accent)
                        .frame(width: 8, height: 8)
                        .opacity(pulse ? 0.35 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pressione o novo atalho…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SettingsTheme.accent)
                        Text(hint ?? "Esc cancela")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ShortcutKeys(parts: keyParts, size: .large)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .background {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .fill(SettingsTheme.fieldFill(colorScheme).opacity(isHovering && !isRecording ? 1.4 : 1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .strokeBorder(
                        isRecording
                            ? SettingsTheme.accent.opacity(pulse ? 0.45 : 0.95)
                            : SettingsTheme.fieldStroke(colorScheme),
                        lineWidth: isRecording ? 1.5 : SettingsTheme.hairline
                    )
            }
            .shadow(color: isRecording ? SettingsTheme.accent.opacity(pulse ? 0.12 : 0.35) : .clear, radius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Esc cancela" : "Clique para gravar outro atalho")
        .onHover { isHovering = $0 }
        .onChange(of: isRecording, initial: true) { _, recording in
            pulse = false
            guard recording else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Teclas

private enum KeyCapSize {
    case small, large
}

private struct ShortcutKeys: View {
    let parts: [HotkeyKeyPart]
    let size: KeyCapSize

    var body: some View {
        HStack(spacing: size == .large ? 6 : 3) {
            ForEach(parts) { part in
                ShortcutKeyCap(symbol: part.symbol, title: part.title, size: size)
            }
        }
    }
}

/// Uma tecla em relevo: face clara sobre uma base mais escura, como uma
/// tecla física vista de cima.
private struct ShortcutKeyCap: View {
    let symbol: String?
    let title: String
    let size: KeyCapSize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let large = size == .large
        HStack(spacing: large ? 6 : 3) {
            if let symbol {
                Text(symbol)
                    .font(.system(size: large ? 15 : 11, weight: .semibold, design: .rounded))
            }
            Text(title)
                .font(.system(size: large ? 14 : 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
        .padding(.horizontal, large ? 13 : 7)
        .frame(minWidth: large ? 38 : 22, minHeight: large ? 36 : 22)
        .background {
            RoundedRectangle(cornerRadius: large ? 9 : 6, style: .continuous)
                .fill(SettingsTheme.cardFill(colorScheme).opacity(2.2))
                .offset(y: large ? 2.5 : 1.5)
        }
        .background {
            RoundedRectangle(cornerRadius: large ? 9 : 6, style: .continuous)
                .fill(SettingsTheme.fieldFill(colorScheme).opacity(1.8))
        }
        .overlay {
            RoundedRectangle(cornerRadius: large ? 9 : 6, style: .continuous)
                .strokeBorder(SettingsTheme.fieldStroke(colorScheme), lineWidth: SettingsTheme.hairline)
        }
        .padding(.bottom, large ? 2.5 : 1.5)
    }
}
