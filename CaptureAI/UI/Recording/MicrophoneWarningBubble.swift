import SwiftUI

/// Balão acima da barra flutuante avisando que o microfone caiu.
///
/// Fica fora da barra de propósito: lá dentro o texto disputava com o vidro e
/// o brilho colorido do estilo moderno e sumia. Aqui o fundo é escuro e
/// sólido, legível sobre qualquer coisa que esteja atrás.
struct MicrophoneWarningBubble: View {
    let symbol: String
    let title: String
    let hint: String
    let message: String

    /// Microfone caiu: a gravação pausou.
    init(interruption: MicrophoneInterruption) {
        symbol = "mic.slash.fill"
        title = interruption.title
        hint = Self.hint(for: interruption)
        message = interruption.message
    }

    /// Microfone escolhido ausente: gravando pelo padrão do macOS.
    init(fallback: MicrophoneFallback) {
        symbol = "mic.badge.xmark"
        title = fallback.title
        hint = fallback.hint
        message = fallback.message
    }

    static let size = CGSize(width: 300, height: 54)

    private static let accent = Color(red: 1.00, green: 0.62, blue: 0.28)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Self.accent.opacity(0.45), lineWidth: 1)
        )
        .help(message)
    }

    /// O que fazer, em uma linha: o play da barra logo abaixo retoma.
    private static func hint(for interruption: MicrophoneInterruption) -> String {
        switch interruption {
        case .disconnected:
            return "Pausada. Reconecte ou toque em ▶ para o padrão."
        case .muted:
            return "Gravação pausada. Tire o mudo e toque em ▶."
        case .stopped:
            return "Gravação pausada. Toque em ▶ para tentar de novo."
        }
    }
}
