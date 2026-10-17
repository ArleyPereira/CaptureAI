import AppKit

/// O que saiu do editor.
enum CaptureEditorResult {
    /// Imagem pronta e o fator pixels/ponto do monitor de origem.
    case copy(CGImage, scale: CGFloat)
    case save(CGImage, scale: CGFloat)
    case cancelled
}

/// Abre um editor por monitor e devolve a decisão do usuário.
///
/// Uma janela por tela porque cada monitor tem seu fator de escala. Só uma
/// delas tem seleção por vez: começar a selecionar num monitor limpa os outros.
@MainActor
final class CaptureEditorController {
    private var windows: [CaptureEditorWindow] = []
    private let model = CaptureEditorModel()
    private var completion: ((CaptureEditorResult) -> Void)?

    var isPresenting: Bool { !windows.isEmpty }

    func present(_ frozen: [ScreenFreezer.FrozenScreen], completion: @escaping (CaptureEditorResult) -> Void) {
        dismiss()
        self.completion = completion
        model.reset()

        model.onCopy = { [weak self] in self?.finish(asCopy: true) }
        model.onSave = { [weak self] in self?.finish(asCopy: false) }
        model.onCancel = { [weak self] in self?.complete(with: .cancelled) }
        model.onChange = { [weak self] in self?.refresh() }

        for item in frozen {
            let window = CaptureEditorWindow(screen: item.screen, frozen: item.image, model: model)
            window.editor.onSelectionStarted = { [weak self] active in
                guard let self else { return }
                for other in self.windows where other.editor !== active {
                    other.editor.clearSelection()
                }
            }
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        // O teclado vai para o monitor onde está o mouse — é onde a pessoa
        // está olhando ao apertar o atalho.
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.editor)
    }

    /// Redesenha e devolve o teclado ao editor ativo.
    ///
    /// Um clique na barra SwiftUI pode levar o foco para ela; sem devolver,
    /// o Esc e o ⌘C parariam de responder depois de escolher uma ferramenta.
    private func refresh() {
        for window in windows {
            window.editor.needsDisplay = true
        }
        if let active = windows.first(where: { $0.editor.selection != nil }) {
            active.makeFirstResponder(active.editor)
        }
    }

    private func finish(asCopy: Bool) {
        guard
            let active = windows.first(where: { $0.editor.selection != nil }),
            let image = active.editor.renderSelection()
        else { return }
        let scale = active.backingScaleFactor
        complete(with: asCopy ? .copy(image, scale: scale) : .save(image, scale: scale))
    }

    private func complete(with result: CaptureEditorResult) {
        let completion = self.completion
        self.completion = nil

        // Some da tela já, mas as janelas só são soltas no próximo ciclo: isto
        // roda de dentro de um evento delas, e desalocar a janela no meio do
        // próprio evento deixa o AppKit com um ponteiro morto.
        for window in windows {
            window.orderOut(nil)
        }
        DispatchQueue.main.async { [weak self] in
            self?.dismiss()
            completion?(result)
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
