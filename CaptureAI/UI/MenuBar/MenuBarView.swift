import SwiftUI

/// Menu enxuto da barra de status (uso diário).
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let viewModel = MenuBarViewModel(appState: appState)

        if !appState.isAccessibilityTrusted {
            Section {
                Text("Acessibilidade pendente — necessária para inserir texto.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Autorizar Acessibilidade…") {
                    viewModel.requestAccessibilityAccess()
                }

                Button("Reiniciar CaptureAI") {
                    viewModel.relaunchForAccessibility()
                }
            }
        }

        Section {
            Button("Configurações") {
                viewModel.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Histórico") {
                viewModel.openHistory()
            }

            Button("Sair") {
                viewModel.quit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            viewModel.refreshAccessibilityStatus()
        }
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
}
