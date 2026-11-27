import Foundation

/// Estilo visual da barra flutuante de gravação.
///
/// A ordem dos casos é a ordem das miniaturas em Aparência: primeiro os
/// estilos animados (vidro + brilho), depois o Clássico e o Nenhuma.
enum RecordingHUDStyle: String, CaseIterable, Identifiable, Sendable {
    case moderno
    case azul
    case verde
    case pink
    case ambar
    case vidro
    case classico
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .moderno: return "Moderno"
        case .azul: return "Azul"
        case .verde: return "Verde"
        case .pink: return "Pink"
        case .ambar: return "Âmbar"
        case .vidro: return "Vidro"
        case .classico: return "Clássico"
        case .none: return "Nenhuma"
        }
    }

    /// `true` quando a barra flutuante deve aparecer durante o ditado.
    var showsFloatingBar: Bool {
        self != .none
    }

    /// `true` nos estilos de vidro com brilho colorido animado.
    var isAnimated: Bool {
        switch self {
        case .moderno, .azul, .verde, .pink, .ambar, .vidro: return true
        case .classico, .none: return false
        }
    }
}
