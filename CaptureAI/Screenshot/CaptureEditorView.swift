import AppKit
import SwiftUI

/// Editor de captura de um monitor: tela congelada, véu, seleção e anotações.
///
/// O desenho é Core Graphics puro porque a seleção precisa seguir o mouse sem
/// um quadro de atraso. A barra de ferramentas é SwiftUI, hospedada como
/// subview e reposicionada a cada mudança da seleção.
final class CaptureEditorView: NSView {
    /// A foto do monitor tirada ao apertar o atalho, em pixels.
    let frozen: CGImage
    private let model: CaptureEditorModel

    /// Avisa o controller que esta tela começou uma seleção — as outras limpam
    /// a delas, porque só existe uma captura por vez.
    var onSelectionStarted: ((CaptureEditorView) -> Void)?

    private(set) var selection: CGRect? {
        didSet { layoutToolbar() }
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private enum Drag {
        case creating(anchor: CGPoint)
        case moving(last: CGPoint)
        case resizing(handle: Handle, original: CGRect)
        case annotating
        /// Arrastando um balão; sem movimento até soltar, o clique abre a edição.
        case movingBubble(id: UUID, last: CGPoint, moved: Bool)
    }

    /// Campo de digitação posto sobre o balão em edição. O balão é desenhado
    /// atrás, sem o texto, e a pessoa vê as letras aparecendo dentro dele.
    private var bubbleTextView: NSTextView?

    private var drag: Drag?
    private var draft: Annotation?
    /// Janela sob o mouse no modo janela, já em coordenadas desta view.
    private var hoveredWindow: (window: CapturableWindow, rect: CGRect)?
    private var cursorPoint: CGPoint?
    private let toolbarHost: NSHostingView<CaptureToolbar>

    /// Pixels por ponto deste monitor.
    private var pixelScale: CGFloat {
        bounds.width > 0 ? CGFloat(frozen.width) / bounds.width : 2
    }

    init(frame: NSRect, frozen: CGImage, model: CaptureEditorModel) {
        self.frozen = frozen
        self.model = model
        self.toolbarHost = NSHostingView(rootView: CaptureToolbar(model: model))
        super.init(frame: frame)
        toolbarHost.isHidden = true
        addSubview(toolbarHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    func clearSelection() {
        guard selection != nil else { return }
        endBubbleEditing()
        selection = nil
        drag = nil
        draft = nil
        needsDisplay = true
    }

    // MARK: - Desenho

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(frozen, in: bounds)

        if model.mode == .window {
            drawWindowMode(context)
            return
        }

        // Véu em tudo, menos na seleção: par-ímpar recorta o miolo.
        let veil = CGMutablePath()
        veil.addRect(bounds)
        if let selection { veil.addRect(selection) }
        context.addPath(veil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fillPath(using: .evenOdd)

        guard let selection else {
            drawGuides(context)
            drawHint(
                context,
                text: model.mode == .text
                    ? "Arraste sobre o texto que quer copiar  ·  T para área  ·  Esc para sair"
                    : "Arraste para selecionar  ·  W para janela  ·  T para texto  ·  F para tela inteira  ·  Esc para sair"
            )
            return
        }

        context.saveGState()
        context.clip(to: selection)
        for annotation in model.annotations {
            AnnotationRenderer.draw(
                annotation, in: context, container: selection,
                hideText: annotation.id == model.editingBubbleID
            )
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: context, container: selection)
        }
        context.restoreGState()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.stroke(selection.insetBy(dx: -0.5, dy: -0.5))

        if model.tool == .adjust || isAdjusting {
            drawHandles(context, in: selection)
        }
        drawSizeBadge(context, for: selection)
    }

    private var isAdjusting: Bool {
        switch drag {
        case .moving, .resizing: return true
        default: return false
        }
    }

    /// Véu com a janela sob o mouse acesa e tingida, como uma prévia do
    /// que o clique vai levar.
    /// Sem véu: no modo janela a tela fica como está, e só o alvo sob o mouse
    /// ganha o tom azul e a borda. Escurecer tudo esconderia justamente as
    /// janelas entre as quais a pessoa está escolhendo.
    private func drawWindowMode(_ context: CGContext) {
        if let hovered = hoveredWindow {
            // A área de trabalho ocupa o monitor inteiro e não tem cantos
            // arredondados; a borda entra um pouco para não sumir na beira.
            let isDesktop = hovered.window.isDesktop
            let rect = isDesktop ? bounds.insetBy(dx: 1.5, dy: 1.5) : hovered.rect
            let radius: CGFloat = isDesktop ? 0 : 12
            let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(shape)
            context.setFillColor(Self.accent.withAlphaComponent(0.16).cgColor)
            context.fillPath()
            context.addPath(shape)
            context.setStrokeColor(Self.accent.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(2.5)
            context.strokePath()
        }
        drawHint(context, text: "Clique numa janela ou na área de trabalho  ·  W para área  ·  F para tela inteira  ·  Esc para sair")
    }

    private static let accent = NSColor(red: 0.35, green: 0.78, blue: 0.98, alpha: 1)

    /// Linhas guia cruzando o monitor sob o mouse, antes da seleção.
    private func drawGuides(_ context: CGContext) {
        guard let point = cursorPoint else { return }
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.move(to: CGPoint(x: point.x, y: bounds.minY))
        context.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        context.move(to: CGPoint(x: bounds.minX, y: point.y))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }

    /// Dica discreta no topo, só enquanto nada foi selecionado.
    private func drawHint(_ context: CGContext, text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let pill = CGRect(
            x: bounds.midX - (size.width + 28) / 2,
            y: bounds.maxY - 90,
            width: size.width + 28,
            height: size.height + 14
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        context.fillPath()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 14, y: pill.minY + 7), withAttributes: attributes)
    }

    private func drawHandles(_ context: CGContext, in rect: CGRect) {
        let size: CGFloat = 8
        for handle in Handle.allCases {
            let point = position(of: handle, in: rect)
            let dot = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: dot)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: dot)
        }
    }

    /// Dimensões em pixels reais, acima do canto superior esquerdo.
    private func drawSizeBadge(_ context: CGContext, for rect: CGRect) {
        let text = "\(Int((rect.width * pixelScale).rounded())) × \(Int((rect.height * pixelScale).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var badge = CGRect(x: rect.minX, y: rect.maxY + 8, width: size.width + 16, height: size.height + 8)
        // Sem espaço acima: entra no canto da seleção.
        if badge.maxY > bounds.maxY - 4 {
            badge.origin.y = rect.maxY - badge.height - 8
            badge.origin.x = rect.minX + 8
        }
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        (text as NSString).draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 4), withAttributes: attributes)
    }

    // MARK: - Barra

    /// Abaixo da seleção, alinhada à direita; acima ou por dentro quando falta espaço.
    private func layoutToolbar() {
        guard let selection, !isCreating, model.mode == .area else {
            toolbarHost.isHidden = true
            return
        }
        let size = toolbarHost.fittingSize
        let gap: CGFloat = 10
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.minY - size.height - gap)
        if origin.y < bounds.minY + gap {
            origin.y = selection.maxY + gap
            if origin.y + size.height > bounds.maxY - gap {
                origin.y = selection.minY + gap
            }
        }
        origin.x = min(max(origin.x, bounds.minX + gap), bounds.maxX - size.width - gap)
        toolbarHost.frame = CGRect(origin: origin, size: size)
        toolbarHost.isHidden = false
    }

    private var isCreating: Bool {
        if case .creating = drag { return true }
        return false
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Clicar fora do balão em edição conclui o texto antes de qualquer coisa.
        endBubbleEditing()

        if model.mode == .window {
            updateHoveredWindow(at: point)
            if let hovered = hoveredWindow {
                model.onCaptureWindow(hovered.window)
            }
            return
        }

        if let selection {
            if let handle = handle(at: point, in: selection) {
                drag = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(point) {
                if model.tool == .bubble {
                    if let hit = bubble(at: point, in: selection) {
                        drag = .movingBubble(id: hit, last: point, moved: false)
                    } else {
                        let bubble = Annotation(tool: .bubble, color: model.color, start: point, end: point)
                        model.annotations.append(bubble)
                        beginBubbleEditing(bubble.id)
                    }
                    needsDisplay = true
                    return
                }
                if model.tool == .adjust {
                    drag = .moving(last: point)
                    NSCursor.closedHand.set()
                } else {
                    draft = Annotation(
                        tool: model.tool,
                        color: model.color,
                        start: point,
                        end: point,
                        lineWidth: model.lineWidth.rawValue,
                        points: model.tool == .pen ? [point] : []
                    )
                    drag = .annotating
                }
                return
            }
        }

        // Fora da seleção: começa outra. As anotações eram da área antiga.
        model.annotations = []
        drag = .creating(anchor: point)
        selection = nil
        onSelectionStarted?(self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil), to: bounds)

        switch drag {
        case .creating(let anchor):
            selection = rect(from: anchor, to: point)

        case .moving(let last):
            guard var rect = selection else { return }
            var dx = point.x - last.x
            var dy = point.y - last.y
            // Presa ao monitor: arrastar para fora não pode cortar a seleção.
            dx = min(max(dx, bounds.minX - rect.minX), bounds.maxX - rect.maxX)
            dy = min(max(dy, bounds.minY - rect.minY), bounds.maxY - rect.maxY)
            rect = rect.offsetBy(dx: dx, dy: dy)
            selection = rect
            // As anotações acompanham a área: elas marcam algo dentro dela.
            model.annotations = model.annotations.map { $0.offsetBy(dx: dx, dy: dy) }
            drag = .moving(last: CGPoint(x: last.x + dx, y: last.y + dy))

        case .resizing(let handle, let original):
            selection = resized(original, by: handle, to: point)

        case .annotating:
            guard let selection else { return }
            let clamped = clamp(point, to: selection)
            draft?.end = clamped
            // Amostras quase no mesmo lugar só engordariam o trajeto.
            if draft?.tool == .pen, let last = draft?.points.last, hypot(clamped.x - last.x, clamped.y - last.y) >= 1.5 {
                draft?.points.append(clamped)
            }

        case .movingBubble(let id, let last, _):
            guard let selection, let index = model.annotations.firstIndex(where: { $0.id == id }) else { return }
            // A ponta fica dentro da seleção: um balão apontando para fora dela
            // apontaria para algo que não está na imagem.
            let target = clamp(point, to: selection)
            let anchor = model.annotations[index].start
            let moved = clamp(CGPoint(x: anchor.x + target.x - last.x, y: anchor.y + target.y - last.y), to: selection)
            model.annotations[index].start = moved
            model.annotations[index].end = moved
            drag = .movingBubble(id: id, last: target, moved: true)

        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            layoutToolbar()
            updateCursor(at: convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        switch drag {
        case .creating:
            // Um clique sem arrasto não é uma seleção.
            if let rect = selection, rect.width < 5 || rect.height < 5 {
                selection = nil
            }
            // No modo texto não há o que ajustar: soltar já entrega o recorte.
            if model.mode == .text, selection != nil {
                model.onExtractText()
            }
        case .annotating:
            if let draft, !draft.isNegligible {
                model.annotations.append(draft)
            }
            draft = nil
        case .movingBubble(let id, _, let moved):
            // Clique sem arrasto num balão é para editar o texto dele.
            if !moved { beginBubbleEditing(id) }
        default:
            break
        }
    }

    // MARK: - Balão de texto

    /// Balão sob o ponto, do mais recente para o mais antigo.
    private func bubble(at point: CGPoint, in selection: CGRect) -> UUID? {
        model.annotations.reversed().first { annotation in
            annotation.tool == .bubble
                && AnnotationRenderer.bubbleLayout(for: annotation, container: selection).bubble.contains(point)
        }?.id
    }

    private func beginBubbleEditing(_ id: UUID) {
        guard let annotation = model.annotations.first(where: { $0.id == id }) else { return }
        model.editingBubbleID = id

        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.focusRingType = .none
        textView.delegate = self
        textView.string = annotation.text
        addSubview(textView)
        bubbleTextView = textView

        styleBubbleTextView()
        layoutBubbleTextView()
        window?.makeFirstResponder(textView)
        needsDisplay = true
    }

    /// Conclui a digitação. Um balão sem texto não tem o que dizer e sai.
    func endBubbleEditing() {
        guard let id = model.editingBubbleID else { return }
        if let textView = bubbleTextView, let index = model.annotations.firstIndex(where: { $0.id == id }) {
            model.annotations[index].text = textView.string
            if model.annotations[index].isNegligible {
                model.annotations.remove(at: index)
            }
        }
        bubbleTextView?.removeFromSuperview()
        bubbleTextView = nil
        model.editingBubbleID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Fonte e cor do campo iguais às do balão, para o texto digitado ser o
    /// mesmo que vai aparecer na imagem.
    private func styleBubbleTextView() {
        guard let textView = bubbleTextView else { return }
        let font = AnnotationRenderer.bubbleFont(scale: 1)
        let color = AnnotationRenderer.bubbleTextColor
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
    }

    /// Posiciona o campo exatamente sobre a área de texto do balão.
    ///
    /// A largura é sempre a máxima do balão: com a largura justa do texto, a
    /// próxima letra quebraria a linha antes de o balão ter a chance de crescer.
    private func layoutBubbleTextView() {
        guard let textView = bubbleTextView, let selection,
              let annotation = model.annotations.first(where: { $0.id == model.editingBubbleID }) else { return }
        let layout = AnnotationRenderer.bubbleLayout(for: annotation, container: selection)
        textView.frame = CGRect(
            x: layout.textRect.minX,
            y: layout.textRect.minY,
            width: layout.maxTextWidth,
            height: layout.textRect.height
        )
    }

    /// Chamado quando a barra muda algo (cor, ferramenta): reaplica o visual
    /// do campo e devolve o teclado a quem estava digitando.
    func restoreFocus() {
        // O desfazer da barra pode ter removido justamente o balão em edição.
        if let id = model.editingBubbleID, !model.annotations.contains(where: { $0.id == id }) {
            bubbleTextView?.removeFromSuperview()
            bubbleTextView = nil
            model.editingBubbleID = nil
        }
        if let textView = bubbleTextView {
            styleBubbleTextView()
            layoutBubbleTextView()
            window?.makeFirstResponder(textView)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if model.mode == .window {
            updateHoveredWindow(at: point)
        }
        updateCursor(at: point)
        if selection == nil { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    /// Primeira janela, da frente para trás, que contém o ponto.
    /// Primeira janela, da frente para trás, que contém o ponto. Fora de
    /// todas, o alvo é a área de trabalho deste monitor — ela se comporta como
    /// mais uma janela, a do fundo.
    private func updateHoveredWindow(at point: CGPoint) {
        let found = model.windows.lazy
            .map { ($0, self.viewRect(fromGlobal: $0.frame)) }
            .first { $0.1.contains(point) }
            ?? (desktopTarget, bounds)
        let changed = found.0 != hoveredWindow?.window
        hoveredWindow = (window: found.0, rect: found.1)
        if changed { needsDisplay = true }
    }

    /// A área de trabalho deste monitor como alvo de captura.
    private var desktopTarget: CapturableWindow {
        let screenFrame = window?.screen?.frame ?? window?.frame ?? .zero
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        return .desktop(frame: CGRect(
            x: screenFrame.minX,
            y: primaryHeight - screenFrame.maxY,
            width: screenFrame.width,
            height: screenFrame.height
        ))
    }

    /// Converte um retângulo global (origem no topo do monitor principal)
    /// para as coordenadas desta view.
    private func viewRect(fromGlobal rect: CGRect) -> CGRect {
        guard let screenFrame = window?.screen?.frame ?? window?.frame else { return .zero }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let cocoaY = primaryHeight - rect.maxY
        return CGRect(
            x: rect.minX - screenFrame.minX,
            y: cocoaY - screenFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Chamado quando o modo muda: a seleção de área não vale no modo janela.
    func modeDidChange() {
        endBubbleEditing()
        selection = nil
        drag = nil
        draft = nil
        hoveredWindow = nil
        layoutToolbar()
        syncWithMouse()
    }

    /// Lê onde o mouse está agora, sem esperar ele se mexer.
    ///
    /// O destaque do modo janela vinha só do `mouseMoved`: quem apertava o
    /// atalho com o cursor parado sobre a área de trabalho (ou sobre uma
    /// janela) não via nada destacado até mover o mouse. Chamado ao abrir o
    /// editor e ao trocar de modo.
    func syncWithMouse() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else {
            // O mouse está em outro monitor: este fica sem alvo.
            cursorPoint = nil
            hoveredWindow = nil
            needsDisplay = true
            return
        }
        cursorPoint = point
        if model.mode == .window {
            updateHoveredWindow(at: point)
        }
        updateCursor(at: point)
        needsDisplay = true
    }

    /// Posição da barra em coordenadas de tela, para abrir o seletor de cor
    /// ao lado dela.
    var toolbarScreenFrame: CGRect? {
        guard !toolbarHost.isHidden, let window else { return nil }
        return window.convertToScreen(convert(toolbarHost.frame, to: nil))
    }

    private static let cameraCursor: NSCursor = {
        let size = NSSize(width: 26, height: 26)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 13, y: 13))
    }()

    /// Cursor aplicado por último, também usado como cursor rect da view.
    private var currentCursor: NSCursor = .crosshair

    /// Aplica o cursor certo para o ponto e o registra como cursor rect.
    ///
    /// Só o `set()` não basta: na abertura do editor o app ainda está
    /// terminando de ficar ativo, e quando a ativação conclui o AppKit
    /// reaplica os cursor rects da janela por cima — sem um rect nosso,
    /// voltava a seta padrão até o mouse se mexer.
    private func updateCursor(at point: CGPoint) {
        let cursor = desiredCursor(at: point)
        cursor.set()
        if cursor !== currentCursor {
            currentCursor = cursor
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    private func desiredCursor(at point: CGPoint) -> NSCursor {
        // Sobre a barra vale a seta do sistema: são botões, não área de captura.
        if !toolbarHost.isHidden, toolbarHost.frame.contains(point) {
            return .arrow
        }
        if model.mode == .window {
            return hoveredWindow != nil ? Self.cameraCursor : .arrow
        }
        guard let selection else { return .crosshair }
        if let handle = handle(at: point, in: selection) {
            return cursor(for: handle)
        }
        if selection.contains(point) {
            return model.tool == .adjust ? .openHand : .crosshair
        }
        return .crosshair
    }

    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft: return .frameResize(position: .topLeft, directions: .all)
        case .topRight: return .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        }
    }

    // MARK: - Teclado

    /// C, S e Z com ⌘ ou Ctrl. Os dois valem porque é comum trocar ⌘ e Ctrl
    /// nos Ajustes para imitar o teclado do Windows — e aí qualquer uma das
    /// duas teclas físicas pode ser a que o dedo procura. No editor o Ctrl não
    /// tem outra função que pudesse conflitar.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleShortcut(event) || super.performKeyEquivalent(with: event)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard model.editingBubbleID == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": model.onCopy(); return true
        case "s": model.onSave(); return true
        case "z": model.undo(); return true
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        // Ctrl+letra nem sempre passa por `performKeyEquivalent`.
        if handleShortcut(event) { return }
        switch event.keyCode {
        case 53: model.onCancel()                       // Esc
        case 36, 76: if selection != nil { model.onCopy() }  // Enter
        case 13: model.toggle(.window)                  // W
        case 17: model.toggle(.text)                    // T
        case 3: model.onFullScreen()                    // F
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Imagem final

    /// Recorta a foto congelada na seleção e grava as anotações por cima,
    /// na resolução real do monitor.
    func renderSelection() -> CGImage? {
        guard let selection else { return nil }
        let scale = pixelScale
        // A foto tem origem no topo; a view, embaixo.
        let pixelRect = CGRect(
            x: selection.minX * scale,
            y: (bounds.height - selection.maxY) * scale,
            width: selection.width * scale,
            height: selection.height * scale
        ).integral

        guard let cropped = frozen.cropping(to: pixelRect) else { return nil }
        guard !model.annotations.isEmpty else { return cropped }

        guard let context = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cropped }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        context.clip(to: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let imageBounds = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        for annotation in model.annotations {
            AnnotationRenderer.draw(annotation, in: context, scale: scale, container: imageBounds) { point in
                CGPoint(x: (point.x - selection.minX) * scale, y: (point.y - selection.minY) * scale)
            }
        }
        return context.makeImage()
    }

    // MARK: - Geometria

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func position(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        }
    }

    /// Alça sob o ponto, com uma margem mais generosa que o desenho —
    /// acertar um ponto de 8 pt com o mouse é difícil.
    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handle in
            let center = position(of: handle, in: rect)
            return hypot(point.x - center.x, point.y - center.y) <= 9
        }
    }

    /// Move as arestas que a alça controla. Arrastar além da aresta oposta
    /// inverte a seleção em vez de travar, como em qualquer editor gráfico.
    private func resized(_ original: CGRect, by handle: Handle, to point: CGPoint) -> CGRect {
        var minX = original.minX, maxX = original.maxX
        var minY = original.minY, maxY = original.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .left: minX = point.x
        case .right: maxX = point.x
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        }
        let rect = CGRect(
            x: min(minX, maxX), y: min(minY, maxY),
            width: max(abs(maxX - minX), 5), height: max(abs(maxY - minY), 5)
        )
        return rect.intersection(bounds)
    }
}

/// Janela em tela cheia de um monitor.
final class CaptureEditorWindow: NSWindow {
    let editor: CaptureEditorView

    init(screen: NSScreen, frozen: CGImage, model: CaptureEditorModel) {
        editor = CaptureEditorView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            frozen: frozen,
            model: model
        )
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Quem segura a janela é o controller, via ARC. Com o padrão (`true`) o
        // `close()` também a liberaria — liberação dupla e crash.
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hasShadow = false
        acceptsMouseMovedEvents = true
        contentView = editor
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension CaptureEditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = bubbleTextView,
              let index = model.annotations.firstIndex(where: { $0.id == model.editingBubbleID }) else { return }
        model.annotations[index].text = textView.string
        layoutBubbleTextView()
        needsDisplay = true
    }

    /// Enter conclui; Shift+Enter quebra a linha. Esc também conclui — sair
    /// da captura inteira por engano no meio de uma frase seria pior.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                endBubbleEditing()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endBubbleEditing()
            return true
        default:
            return false
        }
    }
}
