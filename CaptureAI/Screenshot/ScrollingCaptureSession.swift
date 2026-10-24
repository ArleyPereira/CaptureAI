import AppKit
import CoreMedia
import Observation
import OSLog
import ScreenCaptureKit
import SwiftUI

/// Estado da captura com scroll, compartilhado com os controles na tela.
@Observable
@MainActor
final class ScrollingCaptureState {
    /// Rolagem automática ligada.
    var isAutoScrolling = false
    /// Altura já emendada, em pontos — para o contador da prévia.
    var stitchedPoints: CGFloat = 0
    /// Algum trecho já entrou além do primeiro quadro.
    var hasScrolled = false
    /// Chegou ao limite de altura.
    var reachedLimit = false

    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onToggleAutoScroll: () -> Void = {}
}

/// Captura com scroll: grava a área escolhida enquanto a pessoa rola o
/// conteúdo e emenda os trechos numa imagem só.
///
/// A tela fica viva durante a captura — é preciso ver e rolar o conteúdo de
/// verdade. Por isso nada escurece: só uma moldura marca a área, e os
/// controles e a prévia ficam do lado de fora dela. Todas as janelas do
/// CaptureAI ficam fora da gravação, então nem a moldura nem os controles
/// aparecem na imagem.
@MainActor
final class ScrollingCaptureSession: NSObject {
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "scrolling-capture")
    private let rect: CGRect
    private let screen: NSScreen
    private let completion: (CGImage?, CGFloat) -> Void

    private let state = ScrollingCaptureState()
    private var frameWindow: NSWindow?
    private var controlsPanel: ScrollingControlsPanel?
    private var previewPanel: NSPanel?
    private let previewView = ScrollPreviewView()

    private var stream: SCStream?
    private let output: ScrollStreamOutput
    private var autoScrollTimer: Timer?
    /// Última vez que um trecho novo entrou — a rolagem automática para
    /// sozinha quando a página não anda mais.
    private var lastProgress = Date()
    private var isFinishing = false

    /// - Parameters:
    ///   - rect: a área, em coordenadas globais do Cocoa (origem embaixo).
    ///   - screen: o monitor onde ela está.
    init(rect: CGRect, screen: NSScreen, completion: @escaping (CGImage?, CGFloat) -> Void) {
        self.rect = rect.integral
        self.screen = screen
        self.completion = completion
        self.output = ScrollStreamOutput()
        super.init()
    }

    func start() async throws {
        state.onCancel = { [weak self] in self?.end(keep: false) }
        state.onFinish = { [weak self] in self?.end(keep: true) }
        state.onToggleAutoScroll = { [weak self] in self?.toggleAutoScroll() }

        showFrame()
        showControls()
        showPreview()

        output.onProgress = { [weak self] strips, height in
            Task { @MainActor in self?.progress(strips: strips, height: height) }
        }
        try await startStream()
        logger.notice("Captura com scroll iniciada: \(Int(self.rect.width), privacy: .public)×\(Int(self.rect.height), privacy: .public) pt.")
    }

    // MARK: - Gravação

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let display = content.displays.first(where: { $0.displayID == number.uint32Value })
        else { throw CocoaError(.featureUnsupported) }

        // Tudo do CaptureAI fica de fora: moldura, controles, prévia e as
        // miniaturas que estiverem na tela.
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        // Origem no canto de cima do monitor, em pontos.
        configuration.sourceRect = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        configuration.width = Int(rect.width * scale)
        configuration.height = Int(rect.height * scale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func progress(strips: [CGImage], height: Int) {
        let scale = screen.backingScaleFactor
        state.stitchedPoints = CGFloat(height) / scale
        state.hasScrolled = strips.count > 1
        lastProgress = Date()
        previewView.strips = strips
        layoutPreview()
        if height >= output.maxHeight {
            state.reachedLimit = true
            stopAutoScroll()
        }
    }

    // MARK: - Rolagem automática

    private func toggleAutoScroll() {
        if state.isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    private func startAutoScroll() {
        state.isAutoScrolling = true
        lastProgress = Date()
        // O evento de rolagem vai para a janela sob o ponto onde ele nasce:
        // o centro da área, convertido para a origem no topo que o Quartz usa.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let point = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Sem trecho novo por um tempo: a página acabou.
                if Date().timeIntervalSince(self.lastProgress) > 1.4 {
                    self.stopAutoScroll()
                    return
                }
                guard let event = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -6, wheel2: 0, wheel3: 0
                ) else { return }
                event.location = point
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        state.isAutoScrolling = false
    }

    // MARK: - Fim

    private func end(keep: Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        stopAutoScroll()
        let stream = self.stream
        self.stream = nil
        closeWindows()

        Task {
            try? await stream?.stopCapture()
            let image = keep ? await output.makeImage() : nil
            if keep {
                logger.notice("Captura com scroll concluída: \(image?.width ?? 0, privacy: .public)×\(image?.height ?? 0, privacy: .public) px.")
            } else {
                logger.notice("Captura com scroll cancelada.")
            }
            completion(image, screen.backingScaleFactor)
        }
    }

    private func closeWindows() {
        for window in [frameWindow, controlsPanel, previewPanel] as [NSWindow?] {
            window?.orderOut(nil)
            window?.close()
        }
        frameWindow = nil
        controlsPanel = nil
        previewPanel = nil
    }

    // MARK: - Janelas

    private func showFrame() {
        let inset: CGFloat = -3
        let window = NSWindow(
            contentRect: rect.insetBy(dx: inset, dy: inset),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = ScrollFrameBorderView()
        window.orderFrontRegardless()
        frameWindow = window
    }

    private func showControls() {
        let hosting = ScrollControlsHostingView(rootView: ScrollingControlsView(state: state))
        let size = hosting.fittingSize
        let panel = ScrollingControlsPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.end(keep: false) }
        panel.onFinish = { [weak self] in self?.end(keep: true) }

        // Centralizada logo acima da área; dentro dela, no alto, se não couber.
        let visible = screen.frame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + 10)
        if origin.y + size.height > visible.maxY - 4 {
            origin.y = rect.maxY - size.height - 10
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        controlsPanel = panel
    }

    private static let previewWidth: CGFloat = 150

    private func showPreview() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.previewWidth, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = previewView
        previewPanel = panel
        layoutPreview()
        panel.orderFrontRegardless()
    }

    /// Ao lado da área, alinhada à base dela: à direita, ou à esquerda se
    /// não houver espaço. Cresce para cima conforme a imagem cresce.
    private func layoutPreview() {
        guard let panel = previewPanel else { return }
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        let width = Self.previewWidth
        let maxHeight = max(rect.height, 120)
        let stitched = previewView.stitchedSize
        var height: CGFloat = 80
        if stitched.width > 0 {
            height = min(maxHeight, stitched.height * width / stitched.width)
        }
        var x = rect.maxX + gap
        if x + width > visible.maxX - 8 { x = rect.minX - gap - width }
        x = max(x, visible.minX + 8)
        panel.setFrame(NSRect(x: x, y: rect.minY, width: width, height: height), display: true)
    }
}

// MARK: - Recebimento dos quadros

/// Recebe os quadros da gravação numa fila própria e emenda ali mesmo.
private final class ScrollStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.arley.santana.CaptureAI.scrolling", qos: .userInitiated)
    let maxHeight = 30_000
    private lazy var stitcher = ScrollStitcher(maxHeight: maxHeight)

    /// Chamado na fila de quadros quando entra um trecho novo.
    var onProgress: (@Sendable ([CGImage], Int) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer,
              let frame = Self.copyFrame(pixelBuffer)
        else { return }

        switch stitcher.add(frame) {
        case .started, .appended, .limitReached:
            onProgress?(stitcher.strips, stitcher.stitchedHeight)
        case .unchanged, .noMatch:
            break
        }
    }

    func makeImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: stitcher.makeImage())
            }
        }
    }

    /// Só quadros completos: os ociosos repetem o anterior sem pixels novos.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    /// Copia o buffer para memória própria, linha a linha.
    private static func copyFrame(_ pixelBuffer: CVPixelBuffer) -> ScrollFrame? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(target + row * rowBytes, base + row * sourceStride, rowBytes)
            }
        }
        return ScrollFrame(width: width, height: height, bytesPerRow: rowBytes, data: data)
    }
}

// MARK: - Moldura

/// Contorno ciano com cantos reforçados, como a seleção do editor.
private final class ScrollFrameBorderView: NSView {
    private static let accent = NSColor(red: 0.35, green: 0.78, blue: 0.98, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 2, dy: 2)
        let border = NSBezierPath(rect: box)
        border.lineWidth = 1.5
        Self.accent.withAlphaComponent(0.9).setStroke()
        border.stroke()

        // Cantos em L, mais grossos: marcam a área mesmo sobre conteúdo claro.
        let length: CGFloat = 18
        let corners = NSBezierPath()
        corners.lineWidth = 4
        corners.lineCapStyle = .round
        for (x, dx) in [(box.minX, length), (box.maxX, -length)] {
            for (y, dy) in [(box.minY, length), (box.maxY, -length)] {
                corners.move(to: NSPoint(x: x + dx, y: y))
                corners.line(to: NSPoint(x: x, y: y))
                corners.line(to: NSPoint(x: x, y: y + dy))
            }
        }
        Self.accent.setStroke()
        corners.stroke()
    }
}

// MARK: - Prévia

/// A imagem emendada até agora, encolhida para caber ao lado da área.
private final class ScrollPreviewView: NSView {
    var strips: [CGImage] = [] {
        didSet { needsDisplay = true }
    }

    var stitchedSize: CGSize {
        guard let first = strips.first else { return .zero }
        return CGSize(width: first.width, height: strips.reduce(0) { $0 + $1.height })
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(white: 0.1, alpha: 0.92).setFill()
        shape.fill()

        guard let context = NSGraphicsContext.current?.cgContext, stitchedSize.width > 0 else { return }
        context.saveGState()
        shape.addClip()
        context.interpolationQuality = .medium

        // Encaixa a imagem inteira: quando ela passa da altura da prévia, o
        // conjunto encolhe — o que importa é ver a emenda crescer.
        let size = stitchedSize
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawWidth = size.width * scale
        let originX = (bounds.width - drawWidth) / 2
        var y: CGFloat = 0
        for strip in strips {
            let height = CGFloat(strip.height) * scale
            // A view é invertida; a imagem não: desenha cada parte desvirada.
            context.saveGState()
            context.translateBy(x: originX, y: y + height)
            context.scaleBy(x: 1, y: -1)
            context.draw(strip, in: CGRect(x: 0, y: 0, width: drawWidth, height: height))
            context.restoreGState()
            y += height
        }
        context.restoreGState()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        outline.lineWidth = 1
        outline.stroke()
    }
}

// MARK: - Controles

/// O primeiro clique já aciona o botão: o painel não ativa o app.
private final class ScrollControlsHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Painel dos controles: recebe Esc e Enter sem tirar o foco do app que está
/// sendo rolado.
final class ScrollingControlsPanel: NSPanel {
    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel()            // Esc
        case 36, 76: onFinish()        // Enter
        default: super.keyDown(with: event)
        }
    }
}

private struct ScrollingControlsView: View {
    @Bindable var state: ScrollingCaptureState

    var body: some View {
        HStack(spacing: 8) {
            pill(icon: "xmark", title: "Cancelar", style: .dark, help: "Cancelar (Esc)") { state.onCancel() }

            pill(
                icon: state.isAutoScrolling ? "pause.fill" : "arrow.down.circle",
                title: state.isAutoScrolling ? "Pausar rolagem" : "Rolagem automática",
                style: state.isAutoScrolling ? .active : .dark,
                help: "Rola sozinho até o fim do conteúdo"
            ) { state.onToggleAutoScroll() }
            .disabled(state.reachedLimit)

            pill(icon: "checkmark", title: "Concluir", style: .accent, help: "Concluir (Enter)") { state.onFinish() }
        }
        .padding(4)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private enum PillStyle { case dark, active, accent }

    private func pill(
        icon: String, title: String, style: PillStyle, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(style == .accent ? Color.black.opacity(0.85) : .white)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background {
                Capsule().fill(
                    style == .accent ? SettingsTheme.accent
                        : style == .active ? SettingsTheme.accent.opacity(0.35)
                        : Color(white: 0.12, opacity: 0.92)
                )
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(style == .accent ? 0 : 0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
