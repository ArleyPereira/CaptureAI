import AppKit
import SwiftUI

/// O que o usuário decidiu na janela de revisão.
enum ScreenshotReviewDecision {
    case save(image: NSImage)
    case copy(image: NSImage)
    case saveAs(image: NSImage)
    case discard
}

/// Janela que aparece logo após a seleção, com a imagem em mãos.
///
/// É o que o seletor nativo não oferece: ver o resultado antes de guardar,
/// destacar um trecho e escolher entre copiar e salvar. Fica sem barra de
/// título para não competir com a imagem — o fechar vive nos botões.
@MainActor
final class ScreenshotReviewWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func present(
        image: NSImage,
        destinationLabel: String,
        appearance: NSAppearance?,
        preferredColorScheme: ColorScheme,
        onDecision: @escaping (ScreenshotReviewDecision) -> Void
    ) {
        dismiss()

        let decide: (ScreenshotReviewDecision) -> Void = { [weak self] decision in
            onDecision(decision)
            self?.dismiss()
        }

        let root = ScreenshotReviewContent(
            image: image,
            destinationLabel: destinationLabel,
            onDecision: decide
        )
        .preferredColorScheme(preferredColorScheme)

        // A janela acompanha a proporção da captura, limitada ao que cabe na
        // tela: uma captura de página inteira abriria uma janela maior que o
        // monitor se fosse ao pé da letra.
        let size = Self.windowSize(for: image.size)
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Captura"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 380)
        window.appearance = appearance
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.level = .floating

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cleanup() }
        }

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let window else { return }
        cleanup()
        window.close()
    }

    private func cleanup() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window = nil
    }

    private static func windowSize(for imageSize: NSSize) -> NSSize {
        let chrome = NSSize(width: 48, height: 150)  // margens + barra de ações
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxImage = NSSize(
            width: visible.width * 0.7 - chrome.width,
            height: visible.height * 0.7 - chrome.height
        )

        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: 720, height: 560)
        }
        let scale = min(1, min(maxImage.width / imageSize.width, maxImage.height / imageSize.height))
        return NSSize(
            width: max(460, imageSize.width * scale + chrome.width),
            height: max(380, imageSize.height * scale + chrome.height)
        )
    }
}
