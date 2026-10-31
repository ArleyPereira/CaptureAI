import AppKit
import Observation
import OSLog
import SwiftUI
import Vision
import VisionKit

/// Configuração das leituras de texto do Vision e as que estão em curso.
enum TextRecognitionRequests {
    private nonisolated(unsafe) static var inFlight: [VNRequest] = []
    private static let lock = NSLock()

    /// Cancela as leituras em curso. O Vision atende uma por vez: uma leitura
    /// precisa esquecida recompilando o modelo prenderia a rápida da próxima
    /// captura.
    nonisolated static func cancelAll() {
        lock.lock()
        let requests = inFlight
        inFlight.removeAll()
        lock.unlock()
        requests.forEach { $0.cancel() }
    }

    nonisolated static func perform(_ request: VNRequest, on image: CGImage) throws {
        lock.lock()
        inFlight.append(request)
        lock.unlock()
        defer {
            lock.lock()
            inFlight.removeAll { $0 === request }
            lock.unlock()
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
    }

    nonisolated static func make(_ level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["pt-BR", "en-US"]
        request.automaticallyDetectsLanguage = true
        return request
    }
}

/// Estado do painel de texto, compartilhado entre o AppKit e o SwiftUI.
@Observable
@MainActor
final class TextRecognitionState {
    enum Status: Equatable {
        case analyzing
        case ready
        case empty
        case failed
    }

    /// A seleção de trechos direto na imagem (VisionKit).
    enum Selection: Equatable {
        case loading
        case ready
        /// O serviço do sistema não respondeu a tempo: só o Copiar tudo.
        case unavailable
    }

    var status: Status = .analyzing
    var selection: Selection = .loading
    /// O texto exibido veio da leitura rápida e a precisa ainda não chegou.
    var isRefining = false
    /// Texto inteiro reconhecido, na ordem de leitura.
    var transcript = ""
    /// Há um trecho selecionado na imagem agora.
    var hasSelection = false
    /// Acabou de copiar: o botão mostra a confirmação antes de o painel fechar.
    var didCopy = false

    @ObservationIgnored var onCopy: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
}

/// Mostra o recorte do modo texto com o texto selecionável, como o Texto ao
/// Vivo do sistema, e um botão para copiar tudo de uma vez.
///
/// Tudo roda neste Mac: o VisionKit reconhece o texto localmente, sem rede,
/// e nada é gravado em disco.
@MainActor
final class TextRecognitionPanelController: NSObject, NSWindowDelegate {
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "text-recognition")
    private var panel: TextRecognitionPanel?
    private var state: TextRecognitionState?
    private var overlay: ImageAnalysisOverlayView?
    private var analysisTask: Task<Void, Never>?

    func show(_ image: CGImage, scale: CGFloat) {
        close()

        let state = TextRecognitionState()
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let imageSize = Self.fittedSize(pointSize, in: NSSize(
            width: min(visible.width * 0.7, 960),
            height: min(visible.height * 0.62, 640)
        ))

        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = .textSelection
        // O botão do Texto ao Vivo no canto cobriria o texto de recortes
        // baixos, e a seleção funciona sem ele.
        overlay.isSupplementaryInterfaceHidden = true
        overlay.delegate = self

        let root = TextRecognitionView(
            state: state,
            image: NSImage(cgImage: image, size: pointSize),
            imageSize: imageSize,
            overlay: overlay
        )
        let hosting = FirstMouseHostingView(rootView: root)
        let contentSize = hosting.fittingSize

        let panel = TextRecognitionPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            // Não ativador, como o Spotlight: recebe teclado e clique sem
            // tirar o foco do app em que a pessoa estava. Ativando, o primeiro
            // clique só trazia o CaptureAI para a frente e o botão não reagia.
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = hosting
        panel.delegate = self
        panel.onCopyShortcut = { [weak self] in self?.copy() }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - contentSize.width / 2,
            y: visible.midY - contentSize.height / 2
        ))

        state.onCopy = { [weak self] in self?.copy() }
        state.onClose = { [weak self] in self?.close() }

        self.panel = panel
        self.state = state
        self.overlay = overlay

        panel.makeKeyAndOrderFront(nil)

        analysisTask = Task { [weak self] in
            await self?.analyze(image)
        }
    }

    func close() {
        TextRecognitionRequests.cancelAll()
        analysisTask?.cancel()
        analysisTask = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        state = nil
        overlay = nil
    }

    func windowWillClose(_ notification: Notification) {
        // Fechado pelo botão da barra de título: solta tudo do mesmo jeito.
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    // MARK: - Reconhecimento

    /// Dois reconhecimentos em paralelo, cada um com uma função.
    ///
    /// O texto inteiro sai do Vision, que roda dentro do próprio app e
    /// responde em fração de segundo: é ele que libera o Copiar tudo. A
    /// seleção de trechos na imagem vem do VisionKit, que manda a imagem para
    /// um serviço do sistema (`mediaanalysisd`) — e esse serviço às vezes
    /// leva 30 s para responder. Por isso o painel não espera por ele: a
    /// seleção entra quando chegar, e se demorar o painel avisa.
    private func analyze(_ image: CGImage) async {
        let prepared = Self.upscaledIfSmall(image)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.recognizeText(prepared) }
            group.addTask { await self.prepareSelection(prepared) }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                await self.selectionTimedOut()
            }
        }
    }

    /// Qualidade do texto exibido: uma leitura só substitui outra pior.
    private enum Quality: Int, Comparable {
        case none, fast, accurate
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    private var quality: Quality = .none

    /// Leitura rápida primeiro, precisa depois.
    ///
    /// A precisa acerta mais (acentos, números), mas depende de um modelo do
    /// Neural Engine que o sistema às vezes precisa recompilar — com o disco
    /// quase cheio o macOS apaga esse cache em menos de um minuto, e a leitura
    /// leva de 25 a 40 s. A rápida usa um modelo leve que responde em fração
    /// de segundo mesmo assim: ela libera o Copiar tudo e a precisa troca o
    /// texto quando chegar.
    ///
    /// Em sequência, não em paralelo: o Vision atende uma leitura de texto
    /// por vez no processo, e a rápida ficaria presa atrás da precisa.
    private func recognizeText(_ image: CGImage) async {
        await read(image, level: .fast)
        if quality == .fast { state?.isRefining = true }
        await read(image, level: .accurate)
        guard !Task.isCancelled, let state else { return }
        state.isRefining = false
        if quality == .none, state.status == .analyzing {
            state.status = .empty
        }
    }

    private func read(_ image: CGImage, level: VNRequestTextRecognitionLevel) async {
        let start = Date()
        let text = await Self.recognizeWithVision(image, level: level)
        guard !Task.isCancelled, let state else { return }
        let name = level == .fast ? "rápida" : "precisa"
        logger.notice("Leitura \(name, privacy: .public): \(String(format: "%.2f", Date().timeIntervalSince(start)), privacy: .public) s.")
        guard let text, !text.isEmpty else {
            if level == .accurate { state.isRefining = false }
            return
        }
        apply(transcript: text, quality: level == .fast ? .fast : .accurate)
        if level == .fast, quality == .fast { state.isRefining = true }
        if level == .accurate { state.isRefining = false }
    }

    private func prepareSelection(_ image: CGImage) async {
        guard ImageAnalyzer.isSupported else {
            state?.selection = .unavailable
            return
        }
        let start = Date()
        do {
            let analysis = try await ImageAnalyzer().analyze(
                image,
                orientation: .up,
                configuration: ImageAnalyzer.Configuration([.text])
            )
            guard !Task.isCancelled, let state else { return }
            logger.notice("VisionKit: \(String(format: "%.2f", Date().timeIntervalSince(start)), privacy: .public) s.")
            overlay?.analysis = analysis
            state.selection = .ready
            // A ordem de leitura do VisionKit é a melhor quando ele responde.
            if !analysis.transcript.isEmpty {
                apply(transcript: analysis.transcript, quality: .accurate)
                state.isRefining = false
            }
        } catch {
            logger.error("VisionKit falhou: \(error.localizedDescription, privacy: .public)")
            state?.selection = .unavailable
        }
    }

    private func selectionTimedOut() {
        guard let state, state.selection == .loading else { return }
        state.selection = .unavailable
        logger.notice("VisionKit sem resposta em 4 s; seguindo só com o Copiar tudo.")
    }

    /// Recortes muito baixos (uma linha só) são ampliados: o reconhecimento
    /// precisa de letras com alguma altura para não desistir.
    private nonisolated static func upscaledIfSmall(_ image: CGImage) -> CGImage {
        let factor = min(4, max(1, Int((96.0 / Double(max(1, image.height))).rounded(.up))))
        guard factor > 1,
              let context = CGContext(
                data: nil,
                width: image.width * factor,
                height: image.height * factor,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
        return context.makeImage() ?? image
    }

    private func apply(transcript: String, quality newQuality: Quality) {
        guard let state, newQuality > quality || (newQuality == .accurate && quality == .accurate) else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        quality = max(quality, newQuality)
        state.transcript = trimmed
        state.status = .ready
        logger.notice("Texto reconhecido: \(trimmed.count, privacy: .public) caracteres.")
    }

    private nonisolated static func recognizeWithVision(
        _ image: CGImage,
        level: VNRequestTextRecognitionLevel
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            var request = TextRecognitionRequests.make(level)
            do {
                try TextRecognitionRequests.perform(request, on: image)
            } catch {
                // Cancelada porque o painel fechou: não insiste.
                if Task.isCancelled || (error as NSError).code == VNErrorCode.requestCancelled.rawValue { return nil }
                // O modelo compilado pode ter sido apagado por baixo do
                // processo (erro e5rt): uma segunda tentativa recompila.
                request = TextRecognitionRequests.make(level)
                guard (try? TextRecognitionRequests.perform(request, on: image)) != nil else { return nil }
            }
            // De cima para baixo e, na mesma altura, da esquerda para a direita.
            let observations = (request.results ?? []).sorted { a, b in
                let ay = a.boundingBox.midY, by = b.boundingBox.midY
                if abs(ay - by) > min(a.boundingBox.height, b.boundingBox.height) / 2 { return ay > by }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }

    // MARK: - Copiar

    /// Copia o trecho selecionado, ou tudo quando não há seleção, e fecha.
    private func copy() {
        guard let state, state.status == .ready, !state.didCopy else { return }
        let selected = overlay?.selectedText ?? ""
        let text = (overlay?.hasActiveTextSelection == true && !selected.isEmpty) ? selected : state.transcript
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // O "Copiado" fica um instante na tela: fechar na hora deixaria a
        // pessoa sem saber se a cópia aconteceu.
        state.didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.close()
        }
    }

    // MARK: - Geometria

    /// Cabe a imagem na área máxima sem ampliar: recortes pequenos ficam no
    /// tamanho real, que é o mais legível.
    private static func fittedSize(_ size: NSSize, in bounds: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: 320, height: 200) }
        let ratio = min(1, bounds.width / size.width, bounds.height / size.height)
        return NSSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
    }
}

extension TextRecognitionPanelController: ImageAnalysisOverlayViewDelegate {
    nonisolated func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        MainActor.assumeIsolated {
            state?.hasSelection = overlayView.hasActiveTextSelection
        }
    }
}

/// Aceita o clique que também dá foco à janela: sem isso, o primeiro clique
/// num botão só tornava o painel ativo.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Painel que fecha no Esc e trata o ⌘C mesmo sem seleção.
final class TextRecognitionPanel: NSPanel {
    var onCopyShortcut: () -> Void = {}

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopyShortcut()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Conteúdo

private struct TextRecognitionView: View {
    @Bindable var state: TextRecognitionState
    let image: NSImage
    let imageSize: NSSize
    let overlay: ImageAnalysisOverlayView

    var body: some View {
        VStack(spacing: 0) {
            // Na mesma linha dos botões da barra de título.
            header
                .frame(height: 28)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            LiveTextImage(image: image, overlay: overlay)
                .frame(width: imageSize.width, height: imageSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .overlay {
                    if state.status == .analyzing {
                        ScanningSweep()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 18)

            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 440)
        // O conteúdo começa no topo da janela, sob a barra de título
        // transparente, para o título dividir a linha com os botões dela.
        .ignoresSafeArea(edges: .top)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsTheme.accent)
            Text("Texto da captura")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 12)
        }
        // Espaço para os botões da barra de título, que ficam por cima.
        .padding(.leading, 62)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusLabel
            Spacer(minLength: 12)
            Button("Fechar") { state.onClose() }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button {
                state.onCopy()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(copyTitle)
                }
            }
            .buttonStyle(GradientButtonStyle())
            .disabled(state.status != .ready)
            .help("⌘C")
        }
    }

    private var copyTitle: String {
        if state.didCopy { return "Copiado" }
        return state.hasSelection ? "Copiar seleção" : "Copiar tudo"
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state.status {
        case .analyzing:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Reconhecendo o texto…")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.55))
        case .ready where state.isRefining:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Texto pronto · refinando a leitura…")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.55))
        case .ready:
            switch state.selection {
            case .ready:
                Text(state.hasSelection ? "Trecho selecionado" : "Arraste sobre a imagem para escolher um trecho")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            case .loading:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Texto pronto · preparando a seleção na imagem…")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
            case .unavailable:
                Text("A seleção na imagem está demorando — o Copiar tudo já funciona")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
        case .empty:
            Label("Nenhum texto encontrado nesta área", systemImage: "text.badge.xmark")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(red: 1.00, green: 0.70, blue: 0.35))
        case .failed:
            Label("Não foi possível reconhecer o texto", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(red: 1.00, green: 0.70, blue: 0.35))
        }
    }
}

/// A imagem com a camada do Texto ao Vivo por cima, alinhada a ela.
private struct LiveTextImage: NSViewRepresentable {
    let image: NSImage
    let overlay: ImageAnalysisOverlayView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.trackingImageView = imageView

        container.addSubview(imageView)
        container.addSubview(overlay)
        for view in [imageView, overlay] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Faixa de luz que varre a imagem enquanto o texto é reconhecido.
private struct ScanningSweep: View {
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, SettingsTheme.accent.opacity(0.28), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(proxy.size.height * 0.3, 24))
            .offset(y: proxy.size.height * phase)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }
}
