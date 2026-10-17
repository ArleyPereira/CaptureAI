import Foundation

/// Estilo visual da barra flutuante de gravação.
enum RecordingHUDStyle: String, CaseIterable, Identifiable, Sendable {
    case moderno
    case classico
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .moderno: return "Moderno"
        case .classico: return "Clássico"
        case .none: return "Nenhuma"
        }
    }

    /// `true` quando a barra flutuante deve aparecer durante o ditado.
    var showsFloatingBar: Bool {
        self != .none
    }
}
