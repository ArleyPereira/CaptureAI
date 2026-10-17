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
    }

    private var drag: Drag?
    private var draft: Annotation?
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

        // Véu em tudo, menos na seleção: par-ímpar recorta o miolo.
        let veil = CGMutablePath()
        veil.addRect(bounds)
        if let selection { veil.addRect(selection) }
        context.addPath(veil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fillPath(using: .evenOdd)

        guard let selection else {
            drawGuides(context)
            drawHint(context)
            return
        }

        context.saveGState()
        context.clip(to: selection)
        for annotation in model.annotations {
            AnnotationRenderer.draw(annotation, in: context)
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: context)
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
    private func drawHint(_ context: CGContext) {
        let text = "Arraste para selecionar  ·  Esc para sair"
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
        guard let selection, !isCreating else {
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

        if let selection {
            if let handle = handle(at: point, in: selection) {
                drag = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(point) {
                if model.tool == .adjust {
                    drag = .moving(last: point)
                    NSCursor.closedHand.set()
                } else {
                    draft = Annotation(tool: model.tool, color: model.color, start: point, end: point)
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
            draft?.end = clamp(point, to: selection)

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
        case .annotating:
            if let draft, !draft.isNegligible {
                model.annotations.append(draft)
            }
            draft = nil
        default:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        updateCursor(at: point)
        if selection == nil { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        if selection == nil { needsDisplay = true }
    }

    private func updateCursor(at point: CGPoint) {
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = handle(at: point, in: selection) {
            cursor(for: handle).set()
        } else if selection.contains(point) {
            (model.tool == .adjust ? NSCursor.openHand : NSCursor.crosshair).set()
        } else {
            NSCursor.crosshair.set()
        }
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

    /// ⌘C, ⌘S e ⌘Z chegam como equivalentes de teclado, antes do `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": model.onCopy(); return true
        case "s": model.onSave(); return true
        case "z": model.undo(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: model.onCancel()                       // Esc
        case 36, 76: if selection != nil { model.onCopy() }  // Enter
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
        for annotation in model.annotations {
            AnnotationRenderer.draw(annotation, in: context, scale: scale) { point in
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
