import Foundation

/// Contrato para descoberta do elemento focado via Accessibility.
protocol AccessibilityServiceProtocol: AnyObject {
    /// Indica se o processo confia na Accessibility do sistema.
    func isTrusted() -> Bool

    /// Solicita permissão, se ainda não concedida.
    @discardableResult
    func requestAccess() -> Bool

    /// Captura o elemento atualmente focado no sistema.
    func focusedElement() throws -> FocusedElement
}
