import Carbon
import Foundation

/// Configuração legada / fallback do atalho global de ditado.
enum HotkeyConfiguration {
    /// Código da tecla Tab.
    static let keyCode = DictationHotkey.default.keyCode

    /// Modificador Shift.
    static let modifiers = DictationHotkey.default.modifiers

    /// Texto exibido na interface (⇧ Tab).
    static let displayName = DictationHotkey.default.displayName

    /// Instrução curta de uso.
    static let holdInstruction = DictationHotkey.default.holdInstruction
}
