import AppKit
import Observation
import OSLog
import SwiftUI
import Vision
import VisionKit

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

    var status: Status = .analyzing
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

    private func analyze(_ image: CGImage) async {
        guard let state else { return }

        if ImageAnalyzer.isSupported {
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await ImageAnalyzer().analyze(
                    image,
                    orientation: .up,
                    configuration: configuration
                )
                guard !Task.isCancelled else { return }
                overlay?.analysis = analysis
                apply(transcript: analysis.transcript)
                return
            } catch {
                logger.error("VisionKit falhou: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Sem o VisionKit não há seleção na imagem, mas o texto inteiro ainda
        // sai pelo Vision — o botão de copiar continua funcionando.
        let text = await Self.recognizeWithVision(image)
        guard !Task.isCancelled else { return }
        if let text {
            apply(transcript: text)
        } else {
            state.status = .failed
        }
    }

    private func apply(transcript: String) {
        guard let state else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        state.transcript = trimmed
        state.status = trimmed.isEmpty ? .empty : .ready
        logger.notice("Texto reconhecido: \(trimmed.count, privacy: .public) caracteres.")
    }

    private nonisolated static func recognizeWithVision(_ image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
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
        case .ready:
            Text(state.hasSelection ? "Trecho selecionado" : "Arraste sobre a imagem para escolher um trecho")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
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
