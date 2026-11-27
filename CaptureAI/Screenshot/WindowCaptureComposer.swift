import AppKit
import ScreenCaptureKit

/// Monta a imagem de uma captura de janela: a janela inteira, com sombra,
/// sobre o papel de parede.
///
/// A imagem tem que ser a janela como se via na tela. Sem nada por cima, ela
/// vem da foto congelada no atalho — igual, pixel a pixel, ao modo livre,
/// com o estado de foco e o hover daquele instante. Coberta por outra, ela
/// é refeita só com ela e o que está atrás dela, para sair completa.
///
/// Capturada sozinha (`desktopIndependentWindow`), a janela perde o fundo
/// dos materiais translúcidos: a barra lateral e o fundo saíam num cinza
/// chapado, sem o desfoque do que estava atrás. Dessa captura só se usa o
/// contorno — os cantos arredondados transparentes. O fundo da composição é
/// só a janela do papel de parede — os ícones da mesa são outra janela, do
/// Finder, e ficam de fora.
@MainActor
enum WindowCaptureComposer {
    enum ComposeError: LocalizedError {
        case windowGone

        var errorDescription: String? {
            "A janela não está mais disponível para captura."
        }
    }

    /// Foto de uma janela tirada antes de o editor abrir.
    struct Snapshot {
        let windowID: CGWindowID
        let image: CGImage
        let frame: CGRect
    }

    /// Fotografa a janela sob o mouse no instante do atalho.
    ///
    /// Assim que o editor cobre a tela, a janela embaixo dele perde o hover:
    /// botões que só aparecem com o mouse por cima (os da barra de gravação,
    /// por exemplo) somem antes do clique. A foto antecipada guarda a janela
    /// como estava quando a pessoa apertou o atalho.
    static func snapshot(of target: CapturableWindow, scale: CGFloat) async -> Snapshot? {
        guard
            !target.isDesktop,
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let scWindow = content.windows.first(where: { $0.windowID == target.id }),
            let image = try? await captureWindow(scWindow, scale: scale)
        else { return nil }
        return Snapshot(windowID: target.id, image: image, frame: scWindow.frame)
    }

    static func compose(
        _ target: CapturableWindow,
        on screen: NSScreen,
        frozen: CGImage? = nil,
        snapshot: Snapshot? = nil
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // A área de trabalho é só o papel de parede: sem ícones, sem margem,
        // sem sombra — ela já é o fundo.
        if target.isDesktop {
            guard let wallpaper = try await captureWallpaper(
                content: content, screen: screen, scale: screen.backingScaleFactor
            ) else { throw ComposeError.windowGone }
            return wallpaper
        }

        let scale = screen.backingScaleFactor
        let windowImage: CGImage
        let windowFrame: CGRect
        if let frozen,
           let scWindow = content.windows.first(where: { $0.windowID == target.id }),
           let shape = try? await captureShape(scWindow, scale: scale),
           let masked = mask(frozen, to: shape) {
            windowImage = masked
            windowFrame = target.frame
        } else if let snapshot, snapshot.windowID == target.id {
            windowImage = snapshot.image
            windowFrame = snapshot.frame
        } else {
            guard let scWindow = content.windows.first(where: { $0.windowID == target.id }) else {
                throw ComposeError.windowGone
            }
            windowImage = try await captureWindow(scWindow, scale: scale)
            windowFrame = scWindow.frame
        }
        let wallpaper = try? await captureWallpaper(content: content, screen: screen, scale: scale)

        return render(
            window: windowImage,
            windowFrame: windowFrame,
            wallpaper: wallpaper,
            screen: screen,
            scale: scale
        ) ?? windowImage
    }

    // MARK: - Captura

    /// A janela como aparece na tela, mesmo que outra esteja por cima: o
    /// monitor só com ela e as janelas atrás dela, recortado no retângulo
    /// dela e com o contorno dela.
    ///
    /// As de trás entram para os materiais translúcidos terem o que
    /// desfocar, como na tela. Se não der para montar assim (janela entre
    /// dois monitores, por exemplo), fica a janela sozinha.
    private static func captureWindow(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let shape = try await captureShape(window, scale: scale)
        guard
            let backed = try? await captureWithBackdrop(window, scale: scale),
            let masked = mask(backed, to: shape)
        else { return shape }
        return masked
    }

    private static func captureWithBackdrop(_ window: SCWindow, scale: CGFloat) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(window.frame) }) else { return nil }

        // Ela e as de trás, com o papel de parede, na ordem do `CGWindowList`.
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenBelowWindow, .optionIncludingWindow], window.windowID
        ) as? [[String: Any]] else { return nil }
        let ids = Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let windows = content.windows.filter { ids.contains($0.windowID) }
        guard windows.contains(where: { $0.windowID == window.windowID }) else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: window.frame.minX - display.frame.minX,
            y: window.frame.minY - display.frame.minY,
            width: window.frame.width,
            height: window.frame.height
        )
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, including: windows),
            configuration: configuration
        )
    }

    /// A janela sozinha: o conteúdo sai sem o fundo dos materiais
    /// translúcidos, mas o contorno — cantos arredondados transparentes — é
    /// o exato.
    private static func captureShape(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // A sombra é desenhada por nós, maior e mais suave que a do sistema.
        configuration.ignoreShadowsSingleWindow = true
        // Cantos arredondados transparentes, para a sombra contornar a janela.
        configuration.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }

    /// A imagem recortada no contorno da janela: fica só onde a captura
    /// isolada dela é opaca. As duas têm o retângulo da janela; um pixel a
    /// mais ou a menos do arredondamento é absorvido pela escala.
    private static func mask(_ image: CGImage, to shape: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: shape.width, height: shape.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: shape.width, height: shape.height)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.setBlendMode(.destinationIn)
        context.draw(shape, in: bounds)
        return context.makeImage()
    }

    /// Só a janela do papel de parede deste monitor, sem ícones nem janelas.
    private static func captureWallpaper(content: SCShareableContent, screen: NSScreen, scale: CGFloat) async throws -> CGImage? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let display = content.displays.first(where: { $0.displayID == number.uint32Value })
        else { return nil }

        let wallpaperWindows = content.windows.filter { window in
            window.title == "Wallpaper"
                || (window.owningApplication?.applicationName == "WindowManager" && window.windowLayer < 0)
        }
        guard !wallpaperWindows.isEmpty else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * scale)
        configuration.height = Int(screen.frame.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, including: wallpaperWindows),
            configuration: configuration
        )
    }

    /// Uma modal recortada da tela congelada, no estilo da captura de
    /// janela: cantos arredondados limpos, sobre o papel de parede, com
    /// margem e sombra.
    static func composeModal(_ image: CGImage, frame: CGRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let scale = screen.backingScaleFactor
        let wallpaper = try? await captureWallpaper(content: content, screen: screen, scale: scale)
        let rounded = maskCorners(of: image) ?? image
        return render(window: rounded, windowFrame: frame, wallpaper: wallpaper, screen: screen, scale: scale) ?? rounded
    }

    /// Recorta os cantos arredondados da modal.
    ///
    /// O recorte retangular leva junto, nos cantos, um pedaço do fundo
    /// escurecido da página. O raio não vem da acessibilidade, então é medido
    /// na própria imagem: andando na diagonal a partir de cada canto, conta-se
    /// quanto dura a cor do fundo até a borda da modal começar. Num canto de
    /// raio r essa distância é r·(1 − 1/√2).
    private static func maskCorners(of image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 8, height > 8,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]))
        }
        let limit = min(width, height) / 4
        var distances: [Int] = []
        for (cx, dx) in [(0, 1), (width - 1, -1)] {
            for (cy, dy) in [(0, 1), (height - 1, -1)] {
                let corner = pixel(cx, cy)
                var step = 0
                while step < limit {
                    let p = pixel(cx + dx * step, cy + dy * step)
                    if abs(p.0 - corner.0) + abs(p.1 - corner.1) + abs(p.2 - corner.2) > 12 { break }
                    step += 1
                }
                distances.append(step)
            }
        }
        // A mediana resiste a um canto com conteúdo encostado.
        let sorted = distances.sorted()
        let typical = Double(sorted[1] + sorted[2]) / 2
        let radius = min(typical / (1 - 1 / 2.0.squareRoot()), Double(min(width, height)) / 4)
        guard radius >= 2 else { return image }

        guard let output = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        output.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        output.clip()
        output.draw(image, in: bounds)
        return output.makeImage()
    }

    // MARK: - Composição

    /// Margem ao redor da janela: proporcional ao tamanho dela, com piso, para
    /// a sombra ter onde se espalhar sem ser cortada.
    private static func padding(for size: CGSize) -> CGFloat {
        max(56, min(size.width, size.height) * 0.08)
    }

    private static func render(
        window: CGImage,
        windowFrame: CGRect,
        wallpaper: CGImage?,
        screen: NSScreen,
        scale: CGFloat
    ) -> CGImage? {
        let pad = padding(for: windowFrame.size) * scale
        let windowSize = CGSize(width: window.width, height: window.height)
        let canvas = CGSize(width: windowSize.width + pad * 2, height: windowSize.height + pad * 2)

        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(origin: .zero, size: canvas)

        // Fundo: o trecho do papel de parede que estava atrás da janela.
        if let wallpaper, let region = wallpaperRegion(
            around: windowFrame, padding: pad / scale, screen: screen, scale: scale, wallpaper: wallpaper
        ), let crop = wallpaper.cropping(to: region) {
            drawAspectFill(crop, in: bounds, context: context)
        } else {
            context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
            context.fill(bounds)
        }

        let windowRect = CGRect(x: pad, y: pad, width: windowSize.width, height: windowSize.height)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -14 * scale),
            blur: 44 * scale,
            color: NSColor.black.withAlphaComponent(0.5).cgColor
        )
        context.draw(window, in: windowRect)
        context.restoreGState()

        return context.makeImage()
    }

    /// Retângulo, em pixels da foto do papel de parede, do que estava atrás
    /// da janela mais a margem — preso aos limites do monitor.
    private static func wallpaperRegion(
        around windowFrame: CGRect,
        padding: CGFloat,
        screen: NSScreen,
        scale: CGFloat,
        wallpaper: CGImage
    ) -> CGRect? {
        // Global (origem no topo do principal) → local ao monitor, origem no topo.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenTopLeftY = primaryHeight - screen.frame.maxY
        var local = windowFrame.insetBy(dx: -padding, dy: -padding)
        local.origin.x -= screen.frame.minX
        local.origin.y -= screenTopLeftY

        let pixels = CGRect(
            x: local.minX * scale, y: local.minY * scale,
            width: local.width * scale, height: local.height * scale
        )
        let image = CGRect(x: 0, y: 0, width: wallpaper.width, height: wallpaper.height)
        let clipped = pixels.intersection(image)
        return clipped.isNull || clipped.width < 10 || clipped.height < 10 ? nil : clipped.integral
    }

    private static func drawAspectFill(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let factor = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: CGRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
            width: size.width, height: size.height
        ))
        context.restoreGState()
    }
}
