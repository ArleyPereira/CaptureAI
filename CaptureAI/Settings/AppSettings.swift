import Foundation
import Observation

/// Configurações persistentes da aplicação.
@Observable
@MainActor
final class AppSettings {
    private enum DefaultsKey {
        static let transcriptionLanguage = "settings.transcriptionLanguage"
        static let isTestModeEnabled = "settings.isTestModeEnabled"
        static let keepRecordingsAfterTranscription = "settings.keepRecordingsAfterTranscription"
        static let transcriptionBackend = "settings.transcriptionBackend"
        static let appearanceTheme = "settings.appearanceTheme"
        static let isTranscriptionHistoryEnabled = "settings.isTranscriptionHistoryEnabled"
        static let recordingHUDStyle = "settings.recordingHUDStyle"
        static let hotkeyKeyCode = "settings.hotkeyKeyCode"
        static let hotkeyModifiers = "settings.hotkeyModifiers"
    }

    private let apiKeyStore: any APIKeyProvider
    private let defaults: UserDefaults

    /// Idioma preferido para transcrição (`pt` = português).
    var transcriptionLanguage: String {
        didSet {
            defaults.set(transcriptionLanguage, forKey: DefaultsKey.transcriptionLanguage)
        }
    }

    /// Quando `true`, a transcrição é mock local — **zero** chamada à OpenAI.
    /// Default `true` para proteger créditos até o usuário desligar conscientemente.
    var isTestModeEnabled: Bool {
        didSet {
            defaults.set(isTestModeEnabled, forKey: DefaultsKey.isTestModeEnabled)
        }
    }

    /// Quando `true`, mantém o `.m4a` após transcrever; senão apaga após sucesso.
    var keepRecordingsAfterTranscription: Bool {
        didSet {
            defaults.set(keepRecordingsAfterTranscription, forKey: DefaultsKey.keepRecordingsAfterTranscription)
        }
    }

    /// Backend do ditado: `"api"` (OpenAI) ou `"local"` (Parakeet neste Mac).
    var transcriptionBackend: String {
        didSet {
            defaults.set(transcriptionBackend, forKey: DefaultsKey.transcriptionBackend)
        }
    }

    /// Tema da interface: `system`, `light` ou `dark`.
    var appearanceTheme: String {
        didSet {
            defaults.set(appearanceTheme, forKey: DefaultsKey.appearanceTheme)
        }
    }

    /// Quando `true`, cada ditagem real é salva no histórico local.
    var isTranscriptionHistoryEnabled: Bool {
        didSet {
            defaults.set(isTranscriptionHistoryEnabled, forKey: DefaultsKey.isTranscriptionHistoryEnabled)
        }
    }

    /// Estilo da barra flutuante de gravação (`moderno` / `classico`).
    var recordingHUDStyle: String {
        didSet {
            defaults.set(recordingHUDStyle, forKey: DefaultsKey.recordingHUDStyle)
        }
    }

    /// Código Carbon da tecla do atalho de ditado.
    var hotkeyKeyCode: Int {
        didSet {
            defaults.set(hotkeyKeyCode, forKey: DefaultsKey.hotkeyKeyCode)
        }
    }

    /// Modificadores Carbon do atalho de ditado.
    var hotkeyModifiers: Int {
        didSet {
            defaults.set(hotkeyModifiers, forKey: DefaultsKey.hotkeyModifiers)
        }
    }

    /// Indica se existe API key salva no Keychain (sem expor o valor).
    private(set) var hasAPIKey: Bool

    init(
        apiKeyStore: any APIKeyProvider = OpenAIAPIKeyStore(),
        defaults: UserDefaults = .standard
    ) {
        self.apiKeyStore = apiKeyStore
        self.defaults = defaults

        let storedLanguage = defaults.string(forKey: DefaultsKey.transcriptionLanguage)
        self.transcriptionLanguage = storedLanguage?.isEmpty == false ? storedLanguage! : "pt"

        if defaults.object(forKey: DefaultsKey.isTestModeEnabled) == nil {
            self.isTestModeEnabled = true
        } else {
            self.isTestModeEnabled = defaults.bool(forKey: DefaultsKey.isTestModeEnabled)
        }

        self.keepRecordingsAfterTranscription = defaults.bool(forKey: DefaultsKey.keepRecordingsAfterTranscription)

        let storedBackend = defaults.string(forKey: DefaultsKey.transcriptionBackend)
        self.transcriptionBackend = (storedBackend == "local") ? "local" : "api"

        let storedTheme = defaults.string(forKey: DefaultsKey.appearanceTheme)
        if let storedTheme, AppAppearanceTheme(rawValue: storedTheme) != nil {
            self.appearanceTheme = storedTheme
        } else {
            self.appearanceTheme = AppAppearanceTheme.system.rawValue
        }

        if defaults.object(forKey: DefaultsKey.isTranscriptionHistoryEnabled) == nil {
            self.isTranscriptionHistoryEnabled = true
        } else {
            self.isTranscriptionHistoryEnabled = defaults.bool(forKey: DefaultsKey.isTranscriptionHistoryEnabled)
        }

        let storedHUD = defaults.string(forKey: DefaultsKey.recordingHUDStyle)
        if let storedHUD, RecordingHUDStyle(rawValue: storedHUD) != nil {
            self.recordingHUDStyle = storedHUD
        } else {
            self.recordingHUDStyle = RecordingHUDStyle.moderno.rawValue
        }

        if defaults.object(forKey: DefaultsKey.hotkeyKeyCode) == nil {
            self.hotkeyKeyCode = Int(DictationHotkey.default.keyCode)
        } else {
            self.hotkeyKeyCode = defaults.integer(forKey: DefaultsKey.hotkeyKeyCode)
        }

        if defaults.object(forKey: DefaultsKey.hotkeyModifiers) == nil {
            self.hotkeyModifiers = Int(DictationHotkey.default.modifiers)
        } else {
            self.hotkeyModifiers = defaults.integer(forKey: DefaultsKey.hotkeyModifiers)
        }

        self.hasAPIKey = apiKeyStore.hasAPIKey
    }

    /// Atalho de ditado tipado a partir dos inteiros persistidos.
    var dictationHotkey: DictationHotkey {
        get {
            DictationHotkey(
                keyCode: UInt32(hotkeyKeyCode),
                modifiers: UInt32(hotkeyModifiers)
            )
        }
        set {
            hotkeyKeyCode = Int(newValue.keyCode)
            hotkeyModifiers = Int(newValue.modifiers)
        }
    }

    /// Relê o estado da API key no Keychain.
    func refreshAPIKeyStatus() {
        hasAPIKey = apiKeyStore.hasAPIKey
    }

    /// Obtém a API key (uso interno pelos serviços de transcrição).
    func openAIAPIKey() throws -> String? {
        try apiKeyStore.apiKey()
    }

    /// Salva a API key no Keychain.
    func saveOpenAIAPIKey(_ key: String) throws {
        try apiKeyStore.saveAPIKey(key)
        refreshAPIKeyStatus()
    }

    /// Remove a API key do Keychain.
    func deleteOpenAIAPIKey() throws {
        try apiKeyStore.deleteAPIKey()
        refreshAPIKeyStatus()
    }
}
