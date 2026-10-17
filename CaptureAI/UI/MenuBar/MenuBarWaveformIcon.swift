import AppKit
import SwiftUI

/// Ícone da barra de menu: 5 barras em template AppKit (nítido e visível).
enum MenuBarWaveformIcon {
    /// Gera um `NSImage` template com as barras do AppIcon.
    static func image(pointSize: CGFloat = 16) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixel = max(16, Int((pointSize * scale).rounded()))
        let nsImage = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)

            let heights: [CGFloat] = [0.40, 0.64, 0.88, 0.64, 0.40]
            let barWidth = rect.width * 0.13
            let gap = rect.width * 0.07
            let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            var x = rect.minX + (rect.width - total) / 2

            for factor in heights {
                let barHeight = rect.height * factor
                let y = rect.minY + (rect.height - barHeight) / 2
                let bar = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = CGPath(
                    roundedRect: bar,
                    cornerWidth: barWidth / 2,
                    cornerHeight: barWidth / 2,
                    transform: nil
                )
                context.addPath(path)
                context.fillPath()
                x += barWidth + gap
            }
            return true
        }
        nsImage.isTemplate = true
        // Mantém referência ao tamanho em pontos para o MenuBarExtra.
        nsImage.size = NSSize(width: pointSize, height: pointSize)
        _ = pixel
        return nsImage
    }
}

struct MenuBarWaveformIconView: View {
    var body: some View {
        Image(nsImage: MenuBarWaveformIcon.image())
            .renderingMode(.template)
            .frame(width: 18, height: 16)
            .accessibilityLabel("CaptureAI")
    }
}
