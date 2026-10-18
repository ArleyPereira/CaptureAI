import AppKit
import ScreenCaptureKit

/// Tira uma foto de cada monitor no instante em que a captura começa.
///
/// O editor trabalha sobre essa foto, não sobre a tela viva. É o que garante
/// que a imagem salva é exatamente a que a pessoa viu ao selecionar — um vídeo
/// tocando ou uma notificação chegando no meio do arrasto não mudam nada — e
/// dispensa esconder o véu antes de capturar.
@MainActor
enum ScreenFreezer {
    struct FrozenScreen {
        let screen: NSScreen
        let image: CGImage
    }

    static func freezeAll() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        var frozen: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { continue }

            let configuration = SCStreamConfiguration()
            // Em pixels: é a resolução real do monitor que vai para o arquivo.
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration
            )
            frozen.append(FrozenScreen(screen: screen, image: image))
        }
        return frozen
    }
}
