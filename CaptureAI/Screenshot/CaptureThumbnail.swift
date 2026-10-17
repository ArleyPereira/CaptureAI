import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Miniatura que fica flutuando no canto inferior esquerdo após uma captura.
///
/// Aparece depois de uma captura de janela, que não tem barra de ações na
/// tela: a imagem ainda não foi para lugar nenhum, e a miniatura é onde se
/// decide — copiar, salvar ou descartar. Qualquer ação encerra a miniatura — ela é uma
/// pergunta de uma resposta só. É um painel que não ativa o app: clicar nele
/// não tira o foco de onde a pessoa estava digitando.
@MainActor
final class CaptureThumbnailController {
    private var panel: NSPanel?

    private static let margin: CGFloat = 24

    func show(
        image: CGImage,
        scale: CGFloat,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Bool
    ) {
        dismiss(animated: false)

        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let thumbSize = Self.thumbnailSize
        let nsImage = NSImage(cgImage: image, size: pointSize)

        // Toda ação fecha a miniatura; as que confirmam algo mostram o check
        // por um instante antes, para o clique não parecer ter caído no vazio.
        let closeAfterConfirmation: () -> Void = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                self?.dismiss(animated: true)
            }
        }
        let root = CaptureThumbnailView(
            image: nsImage,
            size: thumbSize,
            onCopy: {
                onCopy()
                closeAfterConfirmation()
            },
            onSave: {
                let ok = onSave()
                closeAfterConfirmation()
                return ok
            },
            onClose: { [weak self] in self?.dismiss(animated: true) }
        )

        // O painel tem exatamente o tamanho da miniatura: a sombra é a nativa
        // da janela, que o sistema desenha fora dos limites dela. Uma sombra
        // SwiftUI precisaria de folga dentro do painel e acabava cortada.
        let panelSize = thumbSize
        let hosting = DraggableThumbnailHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.image = image
        hosting.preview = nsImage
        // Solto numa pasta, o trabalho da miniatura acabou — como no CleanShot.
        hosting.onDropped = { [weak self] in self?.dismiss(animated: true) }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = hosting

        // No monitor onde está o mouse: é onde a captura acabou de acontecer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let finalOrigin = CGPoint(x: visible.minX + Self.margin, y: visible.minY + Self.margin)

        // Entra deslizando da borda esquerda. A posição anima via `setFrame`:
        // o proxy `animator()` não anima `setFrameOrigin`, e a janela ficava
        // parada no ponto de partida, cortada pela borda da tela.
        let finalFrame = NSRect(origin: finalOrigin, size: panelSize)
        panel.setFrame(finalFrame.offsetBy(dx: -40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        // A sombra nativa acompanha o contorno do conteúdo, mas só depois de o
        // SwiftUI desenhar os cantos arredondados; antes disso ela sairia reta.
        DispatchQueue.main.async { panel.invalidateShadow() }
        self.panel = panel
    }

    func dismiss(animated: Bool) {
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            panel.close()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: -40, dy: 0), display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.close()
        }
    }

    /// Tamanho fixo, qualquer que seja o formato da captura: uma miniatura que
    /// muda de forma a cada vez parece outra coisa, e o canto da tela é um
    /// lugar fixo que pede um objeto de tamanho fixo. 210×150 (7:5) é a medida
    /// da miniatura do CleanShot X.
    private static let thumbnailSize = NSSize(width: 210, height: 150)
}

/// Hospeda a miniatura e a torna arrastável como um arquivo de imagem.
///
/// O arraste leva uma *promessa* de arquivo, não um arquivo pronto: quando a
/// pessoa solta numa pasta, o Finder informa o destino e a imagem é gravada
/// direto ali. Não existe cópia temporária — nada sobra para apagar depois —
/// e nada entra na pasta de capturas, então o histórico não muda.
///
/// O arraste é AppKit, e não o `.onDrag` do SwiftUI, porque só o
/// `NSDraggingSource` diz se a imagem foi solta — é isso que fecha a miniatura.
final class DraggableThumbnailHostingView<Content: View>: NSHostingView<Content> {
    var image: CGImage?
    var preview: NSImage?
    var onDropped: (() -> Void)? {
        get { dragSource.onDropped }
        set { dragSource.onDropped = newValue }
    }

    /// Fonte do arraste à parte: o `NSHostingView` já implementa
    /// `NSDraggingSource` para uso interno e não permite sobrescrever.
    private let dragSource = ThumbnailDragSource()

    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDragging = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownPoint else { return }
        // Uma folga antes de virar arraste, para um clique trêmulo nos botões
        // não ser tomado por arrastar.
        let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard distance > 4,
              let image,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            super.mouseDragged(with: event)
            return
        }
        isDragging = true

        let writer = CapturePromiseWriter(png: png)
        let provider = CaptureFilePromiseProvider(fileType: UTType.png.identifier, delegate: writer)
        provider.png = png
        // O Finder pode pedir o arquivo depois que o arraste terminou e a
        // miniatura já fechou; o escritor se mantém vivo até gravar.
        writer.retainUntilWritten()

        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: preview)
        dragSource.onEnded = { [weak self] dropped in
            self?.isDragging = false
            self?.mouseDownPoint = nil
            // Solto em lugar nenhum, a promessa nunca será cobrada.
            if !dropped { writer.release() }
        }
        beginDraggingSession(with: [item], event: event, source: dragSource)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        if !isDragging { super.mouseUp(with: event) }
        isDragging = false
    }
}

/// Promessa de arquivo que também carrega a imagem em si.
///
/// O Finder usa a promessa e grava no destino. Apps que não trabalham com
/// promessas — Mail, Slack, navegadores — recebem o PNG direto da área de
/// arraste.
final class CaptureFilePromiseProvider: NSFilePromiseProvider {
    var png: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? png : super.pasteboardPropertyList(forType: type)
    }
}

/// Grava a imagem onde o Finder pedir, uma única vez.
final class CapturePromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    private let png: Data
    private let fileName: String
    /// Escritores com promessa em aberto. Sem esta referência, o escritor
    /// sumiria junto com a miniatura antes de o Finder cobrar o arquivo.
    @MainActor private static var pending: Set<CapturePromiseWriter> = []

    init(png: Data) {
        self.png = png
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        self.fileName = "captureai-\(formatter.string(from: Date())).png"
    }

    @MainActor func retainUntilWritten() { Self.pending.insert(self) }
    @MainActor func release() { Self.pending.remove(self) }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try png.write(to: url, options: [.atomic])
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
        DispatchQueue.main.async { [self] in release() }
    }
}

/// Diz ao sistema que a miniatura só sai como cópia, e avisa quando ela foi
/// solta em algum lugar.
final class ThumbnailDragSource: NSObject, NSDraggingSource {
    var onDropped: (() -> Void)?
    var onEnded: ((_ dropped: Bool) -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Cópia: soltar numa pasta nunca deve "mover" a captura de lugar algum.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dropped = operation != []
        onEnded?(dropped)
        if dropped { onDropped?() }
    }
}

private struct CaptureThumbnailView: View {
    let image: NSImage
    let size: NSSize
    let onCopy: () -> Void
    let onSave: () -> Bool
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var copied = false
    @State private var saved = false

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()

            if isHovering {
                Color.black.opacity(0.38)
                    .transition(.opacity)

                VStack(spacing: 7) {
                    pill(title: "Copy", confirmed: copied) {
                        guard !copied, !saved else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
                        onCopy()
                    }
                    pill(title: "Save", confirmed: saved) {
                        guard !copied, !saved else { return }
                        if onSave() {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { saved = true }
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94)))

                closeButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(7)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    /// O rótulo nunca muda; a confirmação é o check que aparece ao lado.
    private func pill(title: String, confirmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if confirmed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.12, green: 0.62, blue: 0.86))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Color.black.opacity(0.82))
            .padding(.horizontal, 14)
            .frame(height: 27)
            .background(Capsule().fill(.white.opacity(0.96)))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(0.95)))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Descartar")
    }
}
