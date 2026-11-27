import SwiftUI

/// Cores do brilho animado de cada estilo da barra flutuante.
///
/// Usadas pela barra de verdade (`RecordingOverlay`) e pelas miniaturas em
/// Aparência, para que a prévia mostre as mesmas cores.
struct RecordingHUDPalette {
    /// Gradiente da borda giratória; a primeira cor repete no fim para fechar o ciclo.
    let ring: [Color]
    /// Três manchas desfocadas que passeiam por dentro da cápsula.
    let blobs: [Color]
    /// Tom escuro do vidro, levemente puxado para a cor do estilo.
    let tint: Color

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    static let moderno = RecordingHUDPalette(
        ring: [
            rgb(0.30, 0.85, 1.00),
            rgb(0.42, 0.45, 1.00),
            rgb(0.72, 0.38, 1.00),
            rgb(1.00, 0.42, 0.78),
            rgb(0.30, 0.85, 1.00)
        ],
        blobs: [rgb(0.30, 0.85, 1.00), rgb(0.72, 0.38, 1.00), rgb(1.00, 0.42, 0.78)],
        tint: rgb(0.07, 0.08, 0.10)
    )

    static let azul = RecordingHUDPalette(
        ring: [
            rgb(0.35, 0.90, 1.00),
            rgb(0.18, 0.55, 1.00),
            rgb(0.25, 0.32, 0.98),
            rgb(0.45, 0.72, 1.00),
            rgb(0.35, 0.90, 1.00)
        ],
        blobs: [rgb(0.30, 0.85, 1.00), rgb(0.16, 0.48, 1.00), rgb(0.32, 0.36, 1.00)],
        tint: rgb(0.05, 0.08, 0.14)
    )

    static let verde = RecordingHUDPalette(
        ring: [
            rgb(0.55, 1.00, 0.55),
            rgb(0.18, 0.88, 0.55),
            rgb(0.10, 0.75, 0.72),
            rgb(0.70, 0.95, 0.35),
            rgb(0.55, 1.00, 0.55)
        ],
        blobs: [rgb(0.30, 0.95, 0.55), rgb(0.12, 0.78, 0.70), rgb(0.68, 0.95, 0.35)],
        tint: rgb(0.05, 0.10, 0.08)
    )

    static let pink = RecordingHUDPalette(
        ring: [
            rgb(1.00, 0.55, 0.85),
            rgb(1.00, 0.30, 0.62),
            rgb(0.88, 0.32, 0.95),
            rgb(1.00, 0.52, 0.55),
            rgb(1.00, 0.55, 0.85)
        ],
        blobs: [rgb(1.00, 0.40, 0.75), rgb(0.86, 0.34, 0.96), rgb(1.00, 0.50, 0.55)],
        tint: rgb(0.11, 0.06, 0.10)
    )

    /// Pôr do sol: âmbar, laranja e coral, com um toque de dourado.
    static let ambar = RecordingHUDPalette(
        ring: [
            rgb(1.00, 0.82, 0.35),
            rgb(1.00, 0.60, 0.20),
            rgb(1.00, 0.42, 0.30),
            rgb(1.00, 0.70, 0.45),
            rgb(1.00, 0.82, 0.35)
        ],
        blobs: [rgb(1.00, 0.72, 0.25), rgb(1.00, 0.48, 0.22), rgb(1.00, 0.40, 0.35)],
        tint: rgb(0.12, 0.08, 0.05)
    )

    /// Vidro neutro: tons de prata e branco, sem cor. Na barra de verdade o
    /// fundo é o Liquid Glass do sistema; estas cores servem à borda e à miniatura.
    static let vidro = RecordingHUDPalette(
        ring: [
            Color.white.opacity(0.85),
            Color.white.opacity(0.18),
            Color.white.opacity(0.45),
            Color.white.opacity(0.12),
            Color.white.opacity(0.85)
        ],
        blobs: [Color.white, Color.white, Color.white],
        tint: Color(white: 0.22)
    )
}

extension RecordingHUDStyle {
    /// Paleta do brilho; `nil` nos estilos sem animação (Clássico e Nenhuma).
    var palette: RecordingHUDPalette? {
        switch self {
        case .moderno: return .moderno
        case .azul: return .azul
        case .verde: return .verde
        case .pink: return .pink
        case .ambar: return .ambar
        case .vidro: return .vidro
        case .classico, .none: return nil
        }
    }
}
