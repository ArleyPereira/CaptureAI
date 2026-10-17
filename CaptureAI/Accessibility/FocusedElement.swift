import ApplicationServices
import Foundation

/// Referência ao elemento de interface que estava focado no início da gravação.
struct FocusedElement: @unchecked Sendable {
    /// Elemento AX capturado (mantido vivo enquanto a gravação/inserção ocorre).
    let axElement: AXUIElement

    /// PID do aplicativo dono do elemento.
    let processID: pid_t

    /// Nome do aplicativo focado, quando disponível.
    let applicationName: String?

    /// Papel AX do elemento (ex.: `AXTextField`, `AXTextArea`).
    let role: String?

    /// Descrição curta para UI e logs.
    var summary: String {
        let app = applicationName ?? "App desconhecido"
        let roleLabel = role ?? "elemento"
        return "\(app) · \(roleLabel)"
    }
}
