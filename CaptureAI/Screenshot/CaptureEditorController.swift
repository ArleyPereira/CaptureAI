import AppKit

/// O que saiu do editor.
enum CaptureEditorResult {
    /// Imagem pronta e o fator pixels/ponto do monitor de origem.
    case copy(CGImage, scale: CGFloat)
    case save(CGImage, scale: CGFloat)
    /// Modo janela: a janela escolhida e o monitor onde ela estava.
    case window(CapturableWindow, screen: NSScreen)
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
    private let colorBridge = ColorPanelBridge()
    private var completion: ((CaptureEditorResult) -> Void)?

    var isPresenting: Bool { !windows.isEmpty }

    func present(
        _ frozen: [ScreenFreezer.FrozenScreen],
        mode: CaptureMode,
        capturableWindows: [CapturableWindow],
        completion: @escaping (CaptureEditorResult) -> Void
    ) {
        dismiss()
        self.completion = completion
        model.reset(mode: mode, windows: capturableWindows)

        model.onCopy = { [weak self] in self?.finish(asCopy: true) }
        model.onSave = { [weak self] in self?.finish(asCopy: false) }
        model.onCancel = { [weak self] in self?.complete(with: .cancelled) }
        model.onChange = { [weak self] in self?.refresh() }
        model.onOpenColorPanel = { [weak self] in self?.openColorPanel() }
        model.onCaptureWindow = { [weak self] window in
            guard let self else { return }
            let screen = self.screen(containing: window.frame) ?? NSScreen.main ?? NSScreen.screens[0]
            self.complete(with: .window(window, screen: screen))
        }

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

        // Já na tela, cada editor descobre o que está sob o mouse parado — e
        // de novo um instante depois, quando a ativação do app terminou e o
        // sistema já não vai trocar o cursor por cima.
        for window in windows {
            window.editor.syncWithMouse()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            for window in self?.windows ?? [] {
                window.editor.syncWithMouse()
            }
        }
    }

    /// Troca de modo vinda de fora — o W segurado junto com o Print Screen.
    func setMode(_ mode: CaptureMode) {
        guard isPresenting, model.mode != mode else { return }
        model.toggleMode()
    }

    /// Redesenha e devolve o teclado ao editor ativo.
    ///
    /// Um clique na barra SwiftUI pode levar o foco para ela; sem devolver,
    /// o Esc e o ⌘C parariam de responder depois de escolher uma ferramenta.
    private var lastMode: CaptureMode = .area

    private func refresh() {
        let modeChanged = model.mode != lastMode
        lastMode = model.mode
        for window in windows {
            if modeChanged { window.editor.modeDidChange() }
            window.editor.needsDisplay = true
        }
        let active = windows.first(where: { $0.editor.selection != nil })
            ?? windows.first(where: { $0.isKeyWindow })
            ?? windows.first
        if let active, !NSColorPanel.shared.isKeyWindow {
            active.editor.restoreFocus()
        }
    }

    // MARK: - Cor

    /// Abre o seletor de cores do sistema ao lado da barra.
    ///
    /// O painel precisa subir acima do véu: no nível padrão ele abriria
    /// escondido atrás da janela de captura, que ocupa a tela toda.
    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = model.color
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.setTarget(colorBridge)
        panel.setAction(#selector(ColorPanelBridge.colorDidChange(_:)))
        colorBridge.onChange = { [weak self] color in
            guard let self else { return }
            self.model.select(color)
        }

        // Mostra antes de posicionar: ao aparecer, o painel restaura a última
        // posição salva pelo sistema e desfaria um `setFrameOrigin` anterior.
        panel.orderFront(nil)

        // Logo abaixo da barra, alinhado à direita dela; acima se faltar espaço.
        if let anchor = windows.compactMap(\.editor.toolbarScreenFrame).first {
            let size = panel.frame.size
            var origin = CGPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height - 8)
            if let visible = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame {
                if origin.y < visible.minY + 8 { origin.y = anchor.maxY + 8 }
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            }
            panel.setFrameOrigin(origin)
        }
    }

    private func closeColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        panel.level = .floating
    }

    // MARK: - Saída

    private func finish(asCopy: Bool) {
        guard let active = windows.first(where: { $0.editor.selection != nil }) else { return }
        // Um balão ainda em digitação entra na imagem com o texto que já tem.
        active.editor.endBubbleEditing()
        guard let image = active.editor.renderSelection()
        else { return }
        let scale = active.backingScaleFactor
        complete(with: asCopy ? .copy(image, scale: scale) : .save(image, scale: scale))
    }

    private func complete(with result: CaptureEditorResult) {
        let completion = self.completion
        self.completion = nil
        closeColorPanel()

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

    /// Monitor que contém o centro de um retângulo global (origem no topo).
    private func screen(containing globalRect: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: globalRect.midX, y: primaryHeight - globalRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}

/// Alvo do `NSColorPanel`, que ainda fala por target/action.
final class ColorPanelBridge: NSObject {
    var onChange: ((NSColor) -> Void)?

    @objc func colorDidChange(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
