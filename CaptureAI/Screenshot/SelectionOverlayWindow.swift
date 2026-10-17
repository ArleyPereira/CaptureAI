import AppKit
import CoreGraphics

/// A view que escurece a tela e desenha a seleção.
///
/// Tudo é desenhado aqui, não em SwiftUI: a seleção precisa acompanhar o mouse
/// sem um quadro de atraso, e o recorte "claro dentro, escuro fora" é uma
/// operação de composição que o Core Graphics faz direto.
final class SelectionOverlayView: NSView {
    /// Chamado quando o usuário solta o mouse com uma área válida.
    var onSelected: ((CGRect) -> Void)?
    /// Chamado em Esc ou clique sem arrasto.
    var onCancelled: (() -> Void)?

    private var anchor: CGPoint?
    private var current: CGPoint?
    private var cursorPoint: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    /// Retângulo da seleção em coordenadas desta view.
    private var selection: CGRect? {
        guard let anchor, let current else { return nil }
        let rect = CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Véu escuro sobre tudo.
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fill(bounds)

        guard let selection else {
            drawCrosshair(context)
            return
        }

        // A área escolhida volta ao normal: o recorte é feito limpando o véu,
        // e não desenhando a imagem de novo — a tela real está logo atrás.
        context.setBlendMode(.copy)
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(selection)
        context.setBlendMode(.normal)

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(selection)

        drawHandles(context, in: selection)
        drawSizeBadge(context, for: selection)
    }

    /// Linhas guia cruzando a tela, antes de começar o arrasto.
    private func drawCrosshair(_ context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: CGPoint(x: cursorPoint.x, y: bounds.minY))
        context.addLine(to: CGPoint(x: cursorPoint.x, y: bounds.maxY))
        context.move(to: CGPoint(x: bounds.minX, y: cursorPoint.y))
        context.addLine(to: CGPoint(x: bounds.maxX, y: cursorPoint.y))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }

    /// Quadradinhos nos cantos e no meio das arestas.
    private func drawHandles(_ context: CGContext, in rect: CGRect) {
        let size: CGFloat = 7
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        context.setFillColor(NSColor.white.cgColor)
        for point in points {
            context.fillEllipse(in: CGRect(
                x: point.x - size / 2, y: point.y - size / 2, width: size, height: size
            ))
        }
    }

    /// Etiqueta com as dimensões, em pixels reais da tela.
    private func drawSizeBadge(_ context: CGContext, for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6

        // Acima da seleção; dentro dela quando não há espaço em cima.
        var origin = CGPoint(x: rect.minX, y: rect.maxY + padding)
        if origin.y + size.height + padding > bounds.maxY {
            origin.y = rect.maxY - size.height - padding * 2
        }

        let badge = CGRect(
            x: origin.x, y: origin.y,
            width: size.width + padding * 2, height: size.height + padding
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()

        (text as NSString).draw(
            at: CGPoint(x: badge.minX + padding, y: badge.minY + padding / 2),
            withAttributes: attributes
        )
    }

    // MARK: - Mouse e teclado

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        if anchor == nil { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            current = nil
            needsDisplay = true
        }
        // Clique seco cancela: é o gesto natural de quem desistiu.
        guard let selection, selection.width > 4, selection.height > 4 else {
            onCancelled?()
            return
        }
        onSelected?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onCancelled?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

/// Janela em tela cheia que hospeda a seleção, uma por monitor.
///
/// Substitui o seletor nativo do macOS, que não escurece a tela — a
/// confirmação visual de "estou capturando, escolha a área" é justamente o que
/// se espera de uma ferramenta de captura.
final class SelectionOverlayWindow: NSWindow {
    private let selectionView = SelectionOverlayView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Acima de tudo, inclusive de apps em tela cheia.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        hasShadow = false
        // A janela é excluída de qualquer gravação de tela. Sem isto, o véu
        // escuro entraria na própria captura que ele está ajudando a compor.
        sharingType = .none

        contentView = selectionView
        selectionView.frame = NSRect(origin: .zero, size: screen.frame.size)
        setFrame(screen.frame, display: true)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }

    var onSelected: ((CGRect) -> Void)? {
        get { selectionView.onSelected }
        set { selectionView.onSelected = newValue }
    }

    var onCancelled: (() -> Void)? {
        get { selectionView.onCancelled }
        set { selectionView.onCancelled = newValue }
    }

    /// Converte a seleção local em coordenadas globais de tela (origem no topo),
    /// que é o sistema que o `CGDisplay`/`screencapture` usa.
    func globalRect(from local: CGRect) -> CGRect {
        let frame = self.frame
        let totalHeight = NSScreen.screens
            .map(\.frame.maxY)
            .max() ?? frame.maxY
        return CGRect(
            x: frame.minX + local.minX,
            y: totalHeight - (frame.minY + local.maxY),
            width: local.width,
            height: local.height
        )
    }
}
