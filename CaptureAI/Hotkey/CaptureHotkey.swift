import AppKit
import Carbon
import Foundation

/// Atalho da captura de tela.
///
/// Separado do `DictationHotkey` porque o gesto é outro: ditado é
/// pressionar-e-segurar, captura é um toque só. Juntar os dois num tipo
/// obrigaria cada leitor a saber qual semântica vale em cada lugar.
struct CaptureHotkey: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Print Screen. Em teclados PC essa tecla chega ao macOS como F13 — não
    /// existe código próprio para ela —, e teclados Apple não a têm.
    static let `default` = CaptureHotkey(
        keyCode: UInt32(kVK_F13),
        modifiers: 0
    )

    /// Rótulo curto (ex.: `Print Screen`, `⌥ ⇧ S`).
    var displayName: String {
        let parts = keyParts.map { part in
            if let symbol = part.symbol { return "\(symbol) \(part.title)" }
            return part.title
        }
        return parts.joined(separator: " + ")
    }

    /// Peças para as cápsulas da UI, no mesmo formato do atalho de ditado.
    var keyParts: [HotkeyKeyPart] {
        var parts: [HotkeyKeyPart] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append(.init(symbol: "⌃", title: "Control")) }
        if modifiers & UInt32(optionKey) != 0 { parts.append(.init(symbol: "⌥", title: "Option")) }
        if modifiers & UInt32(shiftKey) != 0 { parts.append(.init(symbol: "⇧", title: "Shift")) }
        if modifiers & UInt32(cmdKey) != 0 { parts.append(.init(symbol: "⌘", title: "Command")) }
        parts.append(.init(symbol: nil, title: Self.keyTitle(for: keyCode)))
        return parts
    }

    /// Monta a partir de um `NSEvent`.
    ///
    /// Ao contrário do ditado, aceita tecla sem modificador: o caso principal é
    /// justamente a tecla Print Screen sozinha. Teclas que digitam caractere
    /// continuam exigindo modificador, senão o atalho roubaria a letra de
    /// qualquer campo de texto do sistema.
    static func from(event: NSEvent) -> CaptureHotkey? {
        let keyCode = UInt32(event.keyCode)
        if keyCode == UInt32(kVK_Escape) { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        let modifierOnlyKeys: Set<UInt32> = [
            UInt32(kVK_Shift), UInt32(kVK_RightShift),
            UInt32(kVK_Control), UInt32(kVK_RightControl),
            UInt32(kVK_Option), UInt32(kVK_RightOption),
            UInt32(kVK_Command), UInt32(kVK_RightCommand),
            UInt32(kVK_Function),
        ]
        guard !modifierOnlyKeys.contains(keyCode) else { return nil }
        guard carbon != 0 || isStandaloneSafe(keyCode) else { return nil }

        return CaptureHotkey(keyCode: keyCode, modifiers: carbon)
    }

    /// Teclas que podem virar atalho sem nenhum modificador.
    ///
    /// Só as de função: elas não produzem texto, então tomá-las não atrapalha
    /// a digitação em nenhum app.
    private static func isStandaloneSafe(_ keyCode: UInt32) -> Bool {
        let functionKeys: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
            kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        return functionKeys.contains(Int(keyCode))
    }

    private static func keyTitle(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        // F13 é o código que a tecla Print Screen dos teclados PC produz.
        // Mostrar "F13" faria a pessoa procurar uma tecla que ela não tem.
        case kVK_F13: return "Print Screen"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            // Para letras e números o rótulo do ditado já resolve; reaproveitar
            // evita duas tabelas que precisariam ser mantidas em sincronia.
            return DictationHotkey(keyCode: keyCode, modifiers: 0).keyParts.last?.title ?? "Tecla \(keyCode)"
        }
    }
}
