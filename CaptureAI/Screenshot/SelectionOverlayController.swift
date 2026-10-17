import AppKit
import Foundation

/// Mostra o véu de seleção em todos os monitores e devolve a área escolhida.
///
/// Uma janela por tela: uma única janela cobrindo a união dos monitores não
/// funciona quando eles têm escalas diferentes, e o `NSScreen` de cada uma é o
/// que dá o fator de escala certo para converter pontos em pixels.
@MainActor
final class SelectionOverlayController {
    private var windows: [SelectionOverlayWindow] = []
    private var completion: ((CGRect?) -> Void)?

    var isPresenting: Bool { !windows.isEmpty }

    /// Apresenta o véu. O retorno é a região em coordenadas globais de tela,
    /// ou `nil` se o usuário cancelou.
    func present(completion: @escaping (CGRect?) -> Void) {
        dismiss()
        self.completion = completion

        for screen in NSScreen.screens {
            let window = SelectionOverlayWindow(screen: screen)
            window.onSelected = { [weak self, weak window] local in
                guard let self, let window else { return }
                let global = window.globalRect(from: local)
                self.finish(with: global)
            }
            window.onCancelled = { [weak self] in
                self?.finish(with: nil)
            }
            window.orderFrontRegardless()
            windows.append(window)
        }

        // Uma das janelas precisa ser a principal para receber o Esc.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func finish(with rect: CGRect?) {
        let completion = self.completion
        self.completion = nil
        dismiss()

        // A captura só pode acontecer depois que o véu saiu da tela, senão ele
        // apareceria na imagem em monitores onde a exclusão de gravação não
        // vale. Um ciclo de run loop basta para a janela sumir de fato.
        DispatchQueue.main.async {
            completion?(rect)
        }
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
