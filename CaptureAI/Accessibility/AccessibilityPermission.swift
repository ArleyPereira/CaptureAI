import ApplicationServices
import AppKit
import Foundation

/// Gerencia a permissão de Acessibilidade do macOS.
enum AccessibilityPermission {
    /// Indica se o processo já está confiável pelo sistema.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Solicita a confiança do processo, mostrando o diálogo nativo se necessário.
    @discardableResult
    static func requestAccess() -> Bool {
        if isTrusted { return true }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Abre Ajustes do Sistema → Privacidade e Segurança → Acessibilidade.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]

        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
}
