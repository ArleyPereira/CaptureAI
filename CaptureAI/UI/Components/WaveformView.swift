import AppKit
import QuartzCore

/// Waveform nativa com CADisplayLink.
final class WaveformNSView: NSView {
    var barCount: Int = 48
    var isActive: Bool = true {
        didSet { updateDisplayLink() }
    }

    private var displayLink: CADisplayLink?
    private var barHeights: [CGFloat] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        barHeights = Array(repeating: 10, count: barCount)
    }

    override var isOpaque: Bool { false }

    /// Deixa o clique passar para o painel arrastar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let levels = LiveAudioMeter.shared.barLevels(count: barCount)
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2
        let spacing = width / CGFloat(barCount)
        // Barras finas e elegantes (mais espaço entre elas).
        let barWidth = max(1.25, min(2.0, spacing * 0.28))

        context.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)

        if barHeights.count != barCount {
            barHeights = Array(repeating: 10, count: barCount)
        }

        // Altura mínima no silêncio (teste: 10).
        let minimumBarHeight: CGFloat = 10

        for index in 0..<barCount {
            let level = CGFloat(levels.indices.contains(index) ? levels[index] : 0.14)
            // Deixa folga nas bordas superior/inferior quando a voz está alta.
            let target = max(minimumBarHeight, level * height * 0.68)
            barHeights[index] += (target - barHeights[index]) * 0.5

            let barHeight = barHeights[index]
            let x = CGFloat(index) * spacing + (spacing - barWidth) / 2
            let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            let corner = barWidth / 2
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
        }
    }

    private func updateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        guard isActive, window != nil else { return }

        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        needsDisplay = true
    }
}

import SwiftUI

struct WaveformView: NSViewRepresentable {
    var isActive: Bool = true
    var barCount: Int = 48

    func makeNSView(context: Context) -> WaveformNSView {
        let view = WaveformNSView(frame: .zero)
        view.barCount = barCount
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: WaveformNSView, context: Context) {
        nsView.barCount = barCount
        nsView.isActive = isActive
    }
}
