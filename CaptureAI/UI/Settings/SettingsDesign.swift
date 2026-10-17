import AppKit
import SwiftUI

/// Paleta e componentes no estilo Super Whisper:
/// fundo uniforme e translúcido, seções em cartões, acento ciano.
/// Cores se adaptam ao tema Sistema / Claro / Escuro.
enum SettingsTheme {
    static let cyan = Color(red: 0.35, green: 0.78, blue: 0.98)
    static let blue = Color(red: 0.35, green: 0.72, blue: 0.98)
    static let purple = Color(red: 0.55, green: 0.58, blue: 0.72)
    static let pink = Color(red: 0.55, green: 0.58, blue: 0.72)

    static let accent = cyan

    static let accentGradient = LinearGradient(
        colors: [cyan, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardCornerRadius: CGFloat = 14
    static let fieldCornerRadius: CGFloat = 12
    static let hairline: CGFloat = 0.8

    static func glassTint(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.10, green: 0.11, blue: 0.16)
            : Color(red: 0.94, green: 0.95, blue: 0.97)
    }

    static func glassOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.62 : 0.55
    }

    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    static func fieldFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    static func fieldStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    static func sidebarSelection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    static func primaryLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.95) : Color(red: 0.12, green: 0.13, blue: 0.16)
    }

    static func secondaryLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.48) : Color.black.opacity(0.45)
    }

    static func tertiaryLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.40)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
    }

    static func ghostFill(_ scheme: ColorScheme, pressed: Bool) -> Color {
        if scheme == .dark {
            return Color.white.opacity(pressed ? 0.12 : 0.08)
        }
        return Color.black.opacity(pressed ? 0.10 : 0.06)
    }

    static func ghostStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }
}

// MARK: - Fundo

/// Fundo da janela: blur nativo + tint uniforme (estilo Super Whisper).
struct SettingsBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SettingsVisualEffect()
            SettingsTheme.glassTint(colorScheme)
                .opacity(SettingsTheme.glassOpacity(colorScheme))
        }
        .ignoresSafeArea()
    }
}

/// Blur nativo do AppKit para o wallpaper aparecer atrás da janela.
struct SettingsVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

// MARK: - Seletor de tema

/// Três miniaturas: Sistema / Claro / Escuro (como no Super Whisper).
struct AppearanceThemePicker: View {
    @Binding var selection: AppAppearanceTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(AppAppearanceTheme.allCases) { theme in
                themeOption(theme)
            }
            Spacer(minLength: 0)
        }
    }

    private func themeOption(_ theme: AppAppearanceTheme) -> some View {
        let isSelected = selection == theme

        return Button {
            selection = theme
        } label: {
            VStack(spacing: 6) {
                themePreview(theme)
                    .frame(width: 72, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? SettingsTheme.accent : SettingsTheme.cardStroke(colorScheme),
                                lineWidth: isSelected ? 2 : SettingsTheme.hairline
                            )
                    }
                    .shadow(color: isSelected ? SettingsTheme.accent.opacity(0.35) : .clear, radius: 5, y: 0)

                Text(theme.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? SettingsTheme.primaryLabel(colorScheme)
                            : SettingsTheme.secondaryLabel(colorScheme)
                    )
            }
        }
        .buttonStyle(.plain)
    }

    /// Miniatura da janela no tema correspondente.
    @ViewBuilder
    private func themePreview(_ theme: AppAppearanceTheme) -> some View {
        switch theme {
        case .system:
            HStack(spacing: 0) {
                previewPane(isDark: true)
                previewPane(isDark: false)
            }
        case .light:
            previewPane(isDark: false)
        case .dark:
            previewPane(isDark: true)
        }
    }

    private func previewPane(isDark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            (isDark ? Color(red: 0.14, green: 0.15, blue: 0.18) : Color(red: 0.93, green: 0.94, blue: 0.96))

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.35) : Color.black.opacity(0.25))
                    .frame(width: 28, height: 3)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12))
                    .frame(width: 40, height: 3)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                    .frame(width: 52, height: 16)
            }
            .padding(8)
        }
    }
}

// MARK: - Seletor da barra flutuante

/// Miniaturas Moderno / Clássico (estilo Super Whisper — Recording window).
struct RecordingHUDStylePicker: View {
    @Binding var selection: RecordingHUDStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(RecordingHUDStyle.allCases) { style in
                styleOption(style)
            }
            Spacer(minLength: 0)
        }
    }

    private func styleOption(_ style: RecordingHUDStyle) -> some View {
        let isSelected = selection == style

        return Button {
            selection = style
        } label: {
            VStack(spacing: 8) {
                hudPreview(style)
                    .frame(width: 108, height: 56)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SettingsTheme.fieldFill(colorScheme))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? SettingsTheme.accent : SettingsTheme.cardStroke(colorScheme),
                                lineWidth: isSelected ? 2 : SettingsTheme.hairline
                            )
                    }
                    .shadow(color: isSelected ? SettingsTheme.accent.opacity(0.35) : .clear, radius: 5, y: 0)

                Text(style.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? SettingsTheme.primaryLabel(colorScheme)
                            : SettingsTheme.secondaryLabel(colorScheme)
                    )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func hudPreview(_ style: RecordingHUDStyle) -> some View {
        switch style {
        case .none:
            Image(systemName: "eye.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .moderno, .classico:
            Capsule()
                .fill(style == .classico ? Color.black : Color(red: 0.10, green: 0.11, blue: 0.14))
                .frame(width: 84, height: 18)
                .overlay {
                    HStack(spacing: 1.5) {
                        ForEach(0..<11, id: \.self) { index in
                            Capsule()
                                .fill(Color.white.opacity(0.85))
                                .frame(width: 2, height: previewBarHeight(index))
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .overlay {
                    if style == .moderno {
                        Capsule()
                            .strokeBorder(
                                AngularGradient(
                                    colors: [
                                        Color(red: 0.30, green: 0.85, blue: 1.00),
                                        Color(red: 0.72, green: 0.38, blue: 1.00),
                                        Color(red: 1.00, green: 0.42, blue: 0.78),
                                        Color(red: 0.30, green: 0.85, blue: 1.00)
                                    ],
                                    center: .center
                                ),
                                lineWidth: 1.2
                            )
                    } else {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                }
        }
    }

    private func previewBarHeight(_ index: Int) -> CGFloat {
        let pattern: [CGFloat] = [4, 7, 11, 8, 14, 9, 12, 6, 10, 5, 8]
        return pattern[index % pattern.count]
    }
}

// MARK: - Cartão

/// Bloco de seção: um pouco mais opaco que o fundo, borda fina.
struct SettingsCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .fill(SettingsTheme.cardFill(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(SettingsTheme.cardStroke(colorScheme), lineWidth: SettingsTheme.hairline)
        }
    }
}

// MARK: - Campos

/// Campo de texto com fundo e borda adaptáveis ao tema.
struct GlassFieldStyle: TextFieldStyle {
    @Environment(\.colorScheme) private var colorScheme

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .fill(SettingsTheme.fieldFill(colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.fieldStroke(colorScheme), lineWidth: SettingsTheme.hairline)
            }
    }
}

// MARK: - Botões

/// Botão principal: cápsula ciano sólida.
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                Capsule().fill(SettingsTheme.accent.opacity(configuration.isPressed ? 0.75 : 0.95))
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: SettingsTheme.hairline)
            }
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Botão secundário: superfície elevada adaptável.
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(SettingsTheme.primaryLabel(colorScheme).opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                Capsule().fill(SettingsTheme.ghostFill(colorScheme, pressed: configuration.isPressed))
            }
            .overlay {
                Capsule().strokeBorder(SettingsTheme.ghostStroke(colorScheme), lineWidth: SettingsTheme.hairline)
            }
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Peças menores

/// Cápsula visual de uma tecla do atalho (ex.: ⇧ Shift, Tab).
struct HotkeyKeyCap: View {
    var symbol: String?
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Text(symbol)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsTheme.fieldFill(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SettingsTheme.fieldStroke(colorScheme), lineWidth: SettingsTheme.hairline)
        }
    }
}

/// Etiqueta de status (verde quando tudo certo, laranja quando pendente).
struct StatusPill: View {
    let text: String
    let isPositive: Bool

    var body: some View {
        let color = isPositive
            ? Color(red: 0.40, green: 0.90, blue: 0.62)
            : Color(red: 1.00, green: 0.70, blue: 0.35)

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: SettingsTheme.hairline))
    }
}

/// Linha com título, descrição e um controle à direita.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var description: String?
    var icon: String?
    var iconColor: Color = .primary
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))

                if let description {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
    }
}

/// Ícone e cor de uma permissão, conforme esteja concedida ou não.
enum PermissionIndicator {
    static func symbol(isGranted: Bool) -> String {
        isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    static func color(isGranted: Bool) -> Color {
        isGranted
            ? Color(red: 0.40, green: 0.90, blue: 0.62)
            : Color(red: 1.00, green: 0.70, blue: 0.35)
    }
}

/// Separador quase invisível entre linhas do mesmo cartão.
struct SettingsDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(SettingsTheme.divider(colorScheme))
            .frame(height: 1)
    }
}
