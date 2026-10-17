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

        // Some da tela já, mas a janela só é solta no próximo ciclo: este
        // método roda de dentro do `mouseUp` da própria view, e desalocar a
        // janela no meio do evento dela deixa o AppKit com um ponteiro morto.
        for window in windows {
            window.orderOut(nil)
        }

        // A captura também espera esse ciclo: é ele que garante que o véu
        // saiu de fato da tela antes de a imagem ser tirada.
        DispatchQueue.main.async { [weak self] in
            self?.dismiss()
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
