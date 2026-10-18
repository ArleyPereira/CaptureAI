import Foundation

/// Motivo pelo qual a ditagem não entrou sozinha no aplicativo.
enum InsertionRescueReason {
    /// Não havia nenhum campo de texto para receber o texto.
    case noFocusedField
    /// Havia um alvo, mas o aplicativo recusou a escrita.
    case insertionRefused

    /// Texto curto exibido no menu/HUD.
    var statusMessage: String {
        switch self {
        case .noFocusedField:
            return "Sem campo em foco: arraste ou copie o texto na barra."
        case .insertionRefused:
            return "O app recusou a inserção: arraste ou copie o texto na barra."
        }
    }
}
