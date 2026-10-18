import SwiftUI

@main
struct CaptureAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarWaveformIconView()
                .help(helpText)
        }
    }

    private var helpText: String {
        let hotkey = appState.settings.dictationHotkey
        switch appState.recordingState {
        case .recording:
            return "CaptureAI — Ouvindo… solte \(hotkey.displayName)"
        case .success:
            return "CaptureAI — Concluído"
        case .error:
            return "CaptureAI — Erro"
        case .awaitingManualInsert:
            return "CaptureAI — Arraste ou copie o texto"
        default:
            return "CaptureAI — \(hotkey.holdInstruction)"
        }
    }
}
