import Foundation

/// Contrato para inserção de texto no aplicativo focado.
protocol TextInsertionService: AnyObject {
    /// Estratégia usada na última inserção (diagnóstico na interface).
    var lastMethod: InsertionMethod? { get }


    /// Insere o texto no alvo apropriado (foco atual).
    func insert(text: String) async throws

    /// Insere o texto usando o elemento capturado no início da gravação.
    func insert(text: String, into captured: FocusedElement) async throws
}
