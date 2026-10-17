import Foundation

/// Contrato para obter a API key da OpenAI sem expor detalhes de armazenamento.
protocol APIKeyProvider: AnyObject {
    /// Indica se há uma chave salva (sem revelar o valor).
    var hasAPIKey: Bool { get }

    /// Devolve a API key ou `nil` se ainda não foi configurada.
    func apiKey() throws -> String?

    /// Persiste a API key no Keychain.
    func saveAPIKey(_ key: String) throws

    /// Remove a API key do Keychain.
    func deleteAPIKey() throws
}

/// Armazena a API key da OpenAI no Keychain do macOS.
final class OpenAIAPIKeyStore: APIKeyProvider, @unchecked Sendable {
    private let service = "dev.arley.santana.CaptureAI.openAI"
    private let account = "apiKey"

    var hasAPIKey: Bool {
        (try? apiKey())?.isEmpty == false
    }

    func apiKey() throws -> String? {
        let value = try KeychainStore.load(service: service, account: account)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }
        try KeychainStore.save(service: service, account: account, value: trimmed)
    }

    func deleteAPIKey() throws {
        try KeychainStore.delete(service: service, account: account)
    }
}
