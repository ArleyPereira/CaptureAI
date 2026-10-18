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
    /// Miniaturas na tela, da mais nova (na frente) para a mais antiga.
    private var stack: [NSPanel] = []
    /// Posição de cada miniatura na pilha, lida pela view.
    private var placements: [ObjectIdentifier: ThumbnailPlacement] = [:]

    private static let margin: CGFloat = 24
    /// Degrau da escada: cada miniatura mais antiga sobe, deixando a borda de
    /// cima aparecendo atrás da nova.
    private static let step = CGSize(width: 0, height: 14)
    /// Miniaturas visíveis na escada. As mais antigas se acumulam atrás da
    /// última e entram no contador acima da pilha, para a escada não subir
    /// pela tela.
    private static let visibleCount = 5
    private static var maxVisibleSteps: Int { visibleCount - 1 }

    /// "+N capturas" acima da pilha, quando há mais do que as visíveis.
    private var counterPanel: NSPanel?
    private let counter = StackCounterModel()

    func show(
        image: CGImage,
        scale: CGFloat,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Bool
    ) {
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let thumbSize = Self.thumbnailSize
        let nsImage = NSImage(cgImage: image, size: pointSize)

        // O painel ainda não existe quando os fechamentos são montados; eles
        // o buscam por esta caixa, preenchida logo abaixo.
        let box = PanelBox()

        // Toda ação fecha a miniatura; as que confirmam algo mostram o check
        // por um instante antes, para o clique não parecer ter caído no vazio.
        let closeAfterConfirmation: () -> Void = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                if let panel = box.panel { self?.dismiss(panel) }
            }
        }
        let placement = ThumbnailPlacement()
        let root = CaptureThumbnailView(
            placement: placement,
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
            onClose: { [weak self] in
                if let panel = box.panel { self?.dismiss(panel) }
            }
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
        hosting.onDropped = { [weak self] in
            if let panel = box.panel { self?.dismiss(panel) }
        }

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
        box.panel = panel

        // A nova entra no degrau da frente; as anteriores sobem um degrau.
        stack.insert(panel, at: 0)
        placements[ObjectIdentifier(panel)] = placement
        let finalFrame = frame(forStep: 0, size: panelSize)

        // Entra deslizando da borda esquerda. A posição anima via `setFrame`:
        // o proxy `animator()` não anima `setFrameOrigin`.
        panel.setFrame(finalFrame.offsetBy(dx: -40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        layoutStack(skipping: panel)
        // A sombra nativa acompanha o contorno do conteúdo, mas só depois de o
        // SwiftUI desenhar os cantos arredondados; antes disso ela sairia reta.
        DispatchQueue.main.async { panel.invalidateShadow() }
    }

    /// Fecha uma miniatura; as que estavam atrás descem um degrau.
    func dismiss(_ panel: NSPanel) {
        guard let index = stack.firstIndex(of: panel) else { return }
        stack.remove(at: index)
        placements[ObjectIdentifier(panel)] = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: -40, dy: 0), display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.close()
        }
        layoutStack()
        restoreOrder()
    }

    /// Some com a pilha durante uma captura — ela apareceria dentro da foto —
    /// sem perder nenhuma miniatura.
    func hideAll() {
        counterPanel?.alphaValue = 0
        hidden = stack
        for panel in hidden {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
        }
    }

    var isEmpty: Bool { stack.isEmpty }

    /// Traz de volta só as que foram escondidas: a nova, que pode estar no
    /// meio da animação de entrada, não é tocada.
    func restoreAll() {
        for panel in hidden where stack.contains(panel) {
            panel.alphaValue = 1
        }
        hidden = []
        updateFront()
        updateCounter()
    }

    /// Escondidas pela captura em andamento.
    private var hidden: [NSPanel] = []

    // MARK: - Escada

    private func frame(forStep step: Int, size: NSSize) -> NSRect {
        // No monitor onde está o mouse: é onde a captura acabou de acontecer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let level = CGFloat(min(step, Self.maxVisibleSteps))
        return NSRect(
            x: visible.minX + Self.margin + level * Self.step.width,
            y: visible.minY + Self.margin + level * Self.step.height,
            width: size.width,
            height: size.height
        )
    }

    /// Só a da frente responde ao mouse: as de trás não mostram controles,
    /// não recebem clique e não podem ser arrastadas.
    private func updateFront() {
        for (index, panel) in stack.enumerated() {
            let isFront = index == 0
            panel.ignoresMouseEvents = !isFront
            placements[ObjectIdentifier(panel)]?.isFront = isFront
        }
    }

    /// Leva cada miniatura ao degrau da sua posição na pilha.
    private func layoutStack(skipping skipped: NSPanel? = nil) {
        updateFront()
        updateCounter()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (index, panel) in stack.enumerated() where panel !== skipped {
                panel.animator().setFrame(frame(forStep: index, size: panel.frame.size), display: true)
            }
        }
    }

    /// Ordem na tela igual à da pilha: a mais nova por cima.
    private func restoreOrder() {
        for panel in stack.reversed() {
            panel.orderFrontRegardless()
        }
    }

    /// Mostra, atualiza ou esconde o "+N capturas" acima da última miniatura
    /// visível.
    private func updateCounter() {
        let hiddenCount = max(0, stack.count - Self.visibleCount)
        counter.count = hiddenCount

        guard hiddenCount > 0, let reference = stack.first else {
            if let panel = counterPanel {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 0 }
            }
            return
        }

        let panel = counterPanel ?? makeCounterPanel()
        counterPanel = panel
        guard let hosting = panel.contentView as? NSHostingView<StackCounterView> else { return }
        let size = hosting.fittingSize
        let top = frame(forStep: Self.maxVisibleSteps, size: reference.frame.size)
        let target = NSRect(x: top.midX - size.width / 2, y: top.maxY + 8, width: size.width, height: size.height)

        if panel.alphaValue < 0.01 {
            panel.setFrame(target, display: true)
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { panel.invalidateShadow() }
    }

    private func makeCounterPanel() -> NSPanel {
        let hosting = NSHostingView(rootView: StackCounterView(model: counter))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Só informa: o clique atravessa para o que estiver embaixo.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.alphaValue = 0
        return panel
    }

    /// Tamanho fixo, qualquer que seja o formato da captura: uma miniatura que
    /// muda de forma a cada vez parece outra coisa, e o canto da tela é um
    /// lugar fixo que pede um objeto de tamanho fixo. 210×150 (7:5) é a medida
    /// da miniatura do CleanShot X.
    private static let thumbnailSize = NSSize(width: 210, height: 150)
}

/// Quantas miniaturas estão escondidas atrás das visíveis.
@Observable
final class StackCounterModel {
    var count = 0
}

/// Pílula grafite "+N capturas", no mesmo vidro escuro do balão de texto e da
/// barra do editor.
struct StackCounterView: View {
    let model: StackCounterModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.stack.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(model.count == 1 ? "+1 captura" : "+\(model.count) capturas")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Capsule().fill(Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.94)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.count)
        .fixedSize()
    }
}

/// Se a miniatura está na frente da pilha — só ela mostra controles.
@Observable
final class ThumbnailPlacement {
    var isFront = true
}

/// Referência tardia ao painel de uma miniatura, para os fechamentos da view.
private final class PanelBox {
    weak var panel: NSPanel?
}

/// Hospeda a miniatura e a torna arrastável como um arquivo de imagem.
///
/// O arraste leva duas formas da mesma imagem, e cada destino usa a sua:
/// - **Promessa de arquivo** — o Finder informa a pasta e a imagem é gravada
///   direto ali, com o ícone no ponto exato da soltura. Copiando um arquivo
///   pronto, o Finder o punha na próxima vaga livre da mesa.
/// - **Arquivo pronto**, gravado no início do arraste — o único formato que
///   Slack, WhatsApp e o Claude aceitam. Só a promessa, sem ele, fazia esses
///   apps recusarem a soltura inteira; o arquivo pronto sob demanda também
///   não servia.
///
/// Nada vai para a pasta de capturas, então o histórico não muda.
///
/// O arraste é AppKit, e não o `.onDrag` do SwiftUI, porque só o
/// `NSDraggingSource` diz se e onde a imagem foi solta.
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
        // O arquivo existe desde o início do arraste: gerado sob demanda, o
        // Finder chegava a pedi-lo mas não copiava.
        guard distance > 4,
              let image,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              let file = DragFile(png: png)
        else {
            super.mouseDragged(with: event)
            return
        }
        isDragging = true

        let writer = PromisedCaptureWriter(png: png, fileName: file.url.lastPathComponent)
        writer.retainUntilWritten()
        let provider = CaptureDragProvider(fileType: UTType.png.identifier, delegate: writer)
        provider.fileURL = file.url
        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        draggingItem.setDraggingFrame(bounds, contents: preview)
        dragSource.onEnded = { [weak self] dropped, point in
            self?.isDragging = false
            self?.mouseDownPoint = nil
            file.finish(droppedAt: dropped ? point : nil)
            // Sem soltura, ou solto num app, a promessa nunca será cobrada.
            if !dropped || !file.wentToFinder { writer.release() }
        }
        beginDraggingSession(with: [draggingItem], event: event, source: dragSource)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        if !isDragging { super.mouseUp(with: event) }
        isDragging = false
    }
}

/// O arquivo temporário de um arraste.
final class DragFile {
    let url: URL

    init?(png: Data) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let url = DragTemporaryFiles.write(png, named: "captureai-\(formatter.string(from: Date())).png") else {
            return nil
        }
        self.url = url
    }

    /// O destino foi o Finder, que usa a promessa e não este arquivo.
    private(set) var wentToFinder = false

    /// Decide quando o temporário pode sumir, conforme quem recebeu.
    ///
    /// Cancelado ou solto no Finder — que grava pela promessa e nem lê este
    /// arquivo —, some na hora. Em outro app fica: Slack e WhatsApp só leem
    /// ao enviar, o que pode levar minutos; vale o prazo geral ou o app fechar.
    func finish(droppedAt point: NSPoint?) {
        let folder = url.deletingLastPathComponent()
        wentToFinder = point.map { DragTemporaryFiles.ownerOfWindow(at: $0) == "Finder" } ?? false
        if point == nil || wentToFinder {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// Promessa de arquivo para o Finder, com o arquivo pronto para os apps.
final class CaptureDragProvider: NSFilePromiseProvider {
    var fileURL: URL?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL] + super.writableTypes(for: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let fileURL {
            return (fileURL as NSURL).pasteboardPropertyList(forType: .fileURL)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Grava a imagem onde o Finder pedir, uma única vez.
final class PromisedCaptureWriter: NSObject, NSFilePromiseProviderDelegate {
    private let png: Data
    private let fileName: String
    /// Escritores com promessa em aberto: o Finder pode cobrá-la depois de o
    /// arraste terminar e a miniatura fechar.
    @MainActor private static var pending: Set<PromisedCaptureWriter> = []

    init(png: Data, fileName: String) {
        self.png = png
        self.fileName = fileName
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

/// Arquivos criados para soltar a captura em outros apps.
enum DragTemporaryFiles {
    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CaptureAI-drag", isDirectory: true)
    }

    /// Prazo para apps que leem o arquivo só ao enviar.
    private static let lifetime: TimeInterval = 600

    static func write(_ png: Data, named name: String) -> URL? {
        removeExpired()
        // Uma subpasta por arraste: o nome do arquivo fica limpo e dois
        // arrastes seguidos não disputam o mesmo caminho.
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    /// App dono da janela mais à frente num ponto da tela (coordenadas do
    /// Cocoa). Inclui a mesa, que é uma janela do Finder.
    ///
    /// Só conta janelas comuns (camada 0) e a mesa (camadas negativas): o Dock
    /// mantém uma janela transparente do tamanho da tela numa camada acima, e
    /// ela seria sempre a "de cima".
    static func ownerOfWindow(at point: NSPoint) -> String? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: point.x, y: primaryHeight - point.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowLayer as String] as? Int ?? 0) <= 0,
                  (info[kCGWindowOwnerName as String] as? String) != "Window Server",
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(target)
            else { continue }
            return info[kCGWindowOwnerName as String] as? String
        }
        return nil
    }

    static func removeExpired() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let limit = Date().addingTimeInterval(-lifetime)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < limit { try? fm.removeItem(at: folder) }
        }
    }

    /// Apaga tudo. Chamado quando o app abre e quando fecha.
    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Diz ao sistema que a miniatura só sai como cópia, e avisa quando ela foi
/// solta em algum lugar.
final class ThumbnailDragSource: NSObject, NSDraggingSource {
    var onDropped: (() -> Void)?
    var onEnded: ((_ dropped: Bool, _ point: NSPoint) -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Cópia: soltar numa pasta nunca deve "mover" a captura de lugar algum.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dropped = operation != []
        onEnded?(dropped, screenPoint)
        if dropped { onDropped?() }
    }
}

private struct CaptureThumbnailView: View {
    let placement: ThumbnailPlacement
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

            // Uma miniatura que foi para trás com o mouse em cima não recebe o
            // "mouse saiu" — ela passa a ignorar o mouse. Sem esta condição,
            // os controles ficariam presos nela.
            if isHovering && placement.isFront {
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
        // Mudou de posição na pilha: o hover que ficou para trás não vale mais.
        .onChange(of: placement.isFront) { isHovering = false }
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
