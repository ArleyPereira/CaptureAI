import AppKit
import Foundation

/// Ações do menu da barra de status.
@MainActor
struct MenuBarViewModel {
    let appState: AppState

    func openSettings() {
        appState.openSettingsWindow()
    }

    func openHistory() {
        appState.openSettingsWindow(tab: .history)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func refreshAccessibilityStatus() {
        appState.refreshAccessibilityStatus()
    }

    func requestAccessibilityAccess() {
        _ = appState.requestAccessibilityAccess()
        presentAccessibilityInstructions()
    }

    func relaunchForAccessibility() {
        appState.relaunchForAccessibility()
    }

    private func presentAccessibilityInstructions() {
        let alert = NSAlert()
        alert.messageText = "Acessibilidade ainda pendente"
        alert.informativeText = """
        Se o toggle do CaptureAI já está azul nos Ajustes, ele pode valer para outra cópia do app.

        1. Em Acessibilidade, selecione CaptureAI.app e remova com −.
        2. Volte ao menu → Autorizar Acessibilidade… e ligue de novo.
        3. Use Reiniciar CaptureAI.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Reiniciar CaptureAI")
        alert.addButton(withTitle: "OK")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AccessibilityPermission.openSystemSettings()
        case .alertSecondButtonReturn:
            appState.relaunchForAccessibility()
        default:
            break
        }
    }
}
