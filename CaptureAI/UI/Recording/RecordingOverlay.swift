import AppKit
import SwiftUI

/// HUD de gravação: waveform, duração e pause/continua.
/// Também exibe a barra de resgate (estilo Spokenly) quando a inserção falha.
///
/// Estilos: **Moderno** (vidro + glow) ou **Clássico** (fundo preto sólido).
struct RecordingOverlay: View {
    @Bindable var appState: AppState
    @State private var glow = OverlayGlowDriver()
    @State private var didCopyFeedback = false
    @State private var isHoveringBar = false

    static let recordingBarSize = CGSize(width: 300, height: 52)
    static let rescueBarSize = CGSize(width: 360, height: 78)

    /// Cores do gradiente giratório (a primeira repete no fim para fechar o ciclo).
    private static let glowColors: [Color] = [
        Color(red: 0.30, green: 0.85, blue: 1.00),
        Color(red: 0.42, green: 0.45, blue: 1.00),
        Color(red: 0.72, green: 0.38, blue: 1.00),
        Color(red: 1.00, green: 0.42, blue: 0.78),
        Color(red: 0.30, green: 0.85, blue: 1.00)
    ]

    private var hudStyle: RecordingHUDStyle {
        RecordingHUDStyle(rawValue: appState.settings.recordingHUDStyle) ?? .moderno
    }

    private var isClassic: Bool { hudStyle == .classico }

    private var isRescue: Bool {
        appState.recordingState == .awaitingManualInsert
            && !(appState.pendingDictationText ?? "").isEmpty
    }

    var body: some View {
        Group {
            if isRescue {
                rescueBar
            } else if let session = appState.playback.session {
                playbackBar(session)
            } else if isCapturing {
                recordingBar
            } else {
                statusBar
            }
        }
        .onAppear { syncGlowDriver() }
        .onDisappear { glow.stop() }
        .onChange(of: appState.recordingState) { _, _ in syncGlowDriver() }
        .onChange(of: appState.settings.recordingHUDStyle) { _, _ in syncGlowDriver() }
    }

    private var isCapturing: Bool {
        appState.recordingState == .recording || appState.recordingState == .paused
    }

    private var isPaused: Bool {
        appState.recordingState == .paused
    }

    /// Mantém a animação só no estilo moderno, enquanto o HUD de captura está à mostra.
    private func syncGlowDriver() {
        if isCapturing, !isClassic, !isRescue {
            glow.start()
        } else {
            glow.stop()
        }
    }

    // MARK: - Resgate (Spokenly-like)

    private var rescueBar: some View {
        let text = appState.pendingDictationText ?? ""

        return ZStack(alignment: .topTrailing) {
            // Área inteira arrastável (exceto os botões acima).
            DictationTextDragSource(text: text) {
                appState.dismissPendingDictation()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help("Arraste para um campo de texto")

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))

                    Text("Arraste para um campo de texto")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)

                    Spacer(minLength: 48)
                }
                .allowsHitTesting(false)

                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                Button(action: copyPendingText) {
                    Image(systemName: didCopyFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(didCopyFeedback ? Color(red: 0.45, green: 0.92, blue: 0.62) : .white.opacity(0.78))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(didCopyFeedback ? "Copiado" : "Copiar")

                Button {
                    appState.dismissPendingDictation()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fechar")
            }
            .padding(.top, 10)
            .padding(.trailing, 12)
        }
        .frame(width: Self.rescueBarSize.width, height: Self.rescueBarSize.height)
        .background { rescueBackground }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(isClassic ? 0.08 : 0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var rescueBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if isClassic {
            shape.fill(Color.black.opacity(0.52))
        } else {
            ZStack {
                FrostedBackground(material: .hudWindow)
                shape.fill(barFill.opacity(0.28))
            }
            .clipShape(shape)
        }
    }

    private func copyPendingText() {
        appState.copyPendingDictation()
        didCopyFeedback = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            didCopyFeedback = false
        }
    }

    // MARK: - Gravação

    private var recordingBar: some View {
        HStack(spacing: 10) {
            WaveformView(isActive: appState.recordingState == .recording, barCount: 42)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

            Text(appState.recordingDurationText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
                .allowsHitTesting(false)

            // Gravando, a barra fica limpa: só onda e duração. Os controles
            // aparecem no hover.
            //
            // Pausado é a exceção: sem o play à vista, uma gravação parada não
            // dá sinal de como continuar, e o usuário teria de descobrir o
            // hover para retomar.
            if isHoveringBar || isPaused {
                pauseButton
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            // Descartar é destrutivo e irreversível, então nunca fica à mostra
            // por padrão — nem pausado.
            if isHoveringBar {
                cancelButton
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Self.recordingBarSize.width, height: Self.recordingBarSize.height)
        .background { barBackground }
        .overlay { barBorder }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHoveringBar = hovering
            }
        }
    }

    // MARK: - Reprodução do histórico

    /// Mesma barra da gravação, com o tempo subindo a partir de zero.
    ///
    /// Os controles seguem a mesma regra da captura: escondidos até o hover,
    /// exceto o play quando está pausado — sem ele à vista, uma reprodução
    /// parada não dá sinal de como continuar.
    private func playbackBar(_ session: AudioPlaybackController.Session) -> some View {
        HStack(spacing: 10) {
            WaveformView(isActive: !session.isPaused, barCount: 42)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

            Text(session.elapsedLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
                .allowsHitTesting(false)

            if isHoveringBar || session.isPaused {
                circleButton(
                    icon: session.isPaused ? "play.fill" : "pause.fill",
                    help: session.isPaused ? "Continuar" : "Pausar"
                ) {
                    appState.playback.togglePause()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if isHoveringBar {
                circleButton(icon: "xmark", help: "Fechar") {
                    appState.stopHistoryAudio()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Self.recordingBarSize.width, height: Self.recordingBarSize.height)
        .background { barBackground }
        .overlay { barBorder }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHoveringBar = hovering
            }
        }
    }

    /// Botão redondo da barra — o visual é o mesmo em gravação e reprodução.
    private func circleButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(isClassic ? 0.12 : 0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(isClassic ? 0.10 : 0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var pauseButton: some View {
        Button {
            Task {
                if appState.recordingState == .paused {
                    await appState.resumeDictation()
                } else {
                    await appState.pauseDictation()
                }
            }
        } label: {
            Image(systemName: appState.recordingState == .paused ? "play.fill" : "pause.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(isClassic ? 0.12 : 0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(isClassic ? 0.10 : 0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(appState.recordingState == .paused ? "Continuar" : "Pausar")
    }

    /// Descarta a ditagem: nada é transcrito, inserido ou salvo no histórico.
    private var cancelButton: some View {
        Button {
            Task { await appState.cancelDictation() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(isClassic ? 0.12 : 0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(isClassic ? 0.10 : 0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Descartar gravação")
    }

    @ViewBuilder
    private var barBackground: some View {
        if isClassic {
            Capsule()
                .fill(Color.black.opacity(0.92))
        } else {
            ZStack {
                FrostedBackground()
                Capsule().fill(barFill.opacity(0.55))
                innerGlow
            }
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var barBorder: some View {
        if isClassic {
            Capsule()
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        } else {
            animatedBorder
        }
    }

    /// Manchas coloridas desfocadas que passeiam por dentro da cápsula.
    private var innerGlow: some View {
        ZStack {
            glowBlob(color: Self.glowColors[0], angleOffset: 0)
            glowBlob(color: Self.glowColors[2], angleOffset: 130)
            glowBlob(color: Self.glowColors[3], angleOffset: 245)
        }
        .blur(radius: 26)
        .opacity(0.34 + glow.intensity * 0.42)
        .blendMode(.plusLighter)
    }

    private func glowBlob(color: Color, angleOffset: Double) -> some View {
        let radians = (glow.phase + angleOffset) * .pi / 180
        let horizontalReach = Self.recordingBarSize.width * 0.36

        return Circle()
            .fill(color)
            .frame(width: 96, height: 96)
            .offset(x: cos(radians) * horizontalReach, y: sin(radians) * 12)
    }

    /// Borda com gradiente angular girando + halo interno.
    private var animatedBorder: some View {
        let gradient = AngularGradient(
            colors: Self.glowColors,
            center: .center,
            angle: .degrees(glow.phase)
        )

        return Capsule()
            .strokeBorder(gradient, lineWidth: 1.4)
            .overlay {
                Capsule()
                    .strokeBorder(gradient, lineWidth: 3.5)
                    .blur(radius: 5)
                    .opacity(0.45 + glow.intensity * 0.45)
            }
            .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: trailingSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)

            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 220, height: Self.recordingBarSize.height)
        .background {
            if isClassic {
                Capsule().fill(Color.black.opacity(0.92))
            } else {
                ZStack {
                    FrostedBackground()
                    Capsule().fill(barFill.opacity(0.55))
                }
                .clipShape(Capsule())
            }
        }
        .overlay {
            Capsule().strokeBorder(.white.opacity(isClassic ? 0.10 : 0.12), lineWidth: 1)
        }
    }

    private var barFill: Color {
        Color(red: 0.07, green: 0.08, blue: 0.10)
    }

    private var accentColor: Color {
        switch appState.recordingState {
        case .success:
            return Color(red: 0.45, green: 0.92, blue: 0.62)
        case .error:
            return Color(red: 1.00, green: 0.62, blue: 0.28)
        case .paused:
            return Color(red: 1.00, green: 0.78, blue: 0.35)
        default:
            return Color(red: 0.30, green: 0.88, blue: 0.80)
        }
    }

    private var trailingSymbol: String {
        switch appState.recordingState {
        case .success:
            return "checkmark"
        case .error:
            return "exclamationmark"
        case .paused:
            return "pause.fill"
        default:
            return "mic.fill"
        }
    }

    private var title: String {
        switch appState.recordingState {
        case .success:
            return "Concluído"
        case .error:
            return "Erro"
        case .paused:
            return "Pausado"
        case .transcribing:
            return "Transcrevendo…"
        case .inserting:
            return "Inserindo…"
        case .awaitingManualInsert:
            return "Texto pronto"
        default:
            return ""
        }
    }
}

/// Blur translúcido do que está atrás do painel (não afeta texto/waveform).
private struct FrostedBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
    }
}

/// Fonte de arraste AppKit para soltar texto em campos de outros apps.
private struct DictationTextDragSource: NSViewRepresentable {
    let text: String
    var onSuccessfulDrop: () -> Void

    func makeNSView(context: Context) -> DictationTextDragNSView {
        let view = DictationTextDragNSView()
        view.text = text
        view.onSuccessfulDrop = onSuccessfulDrop
        return view
    }

    func updateNSView(_ nsView: DictationTextDragNSView, context: Context) {
        nsView.text = text
        nsView.onSuccessfulDrop = onSuccessfulDrop
    }
}

private final class DictationTextDragNSView: NSView, NSDraggingSource {
    var text: String = ""
    var onSuccessfulDrop: (() -> Void)?
    private var pendingDropCompletion: (() -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Só captura eventos se houver texto para arrastar.
        guard !text.isEmpty, bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !text.isEmpty else { return }

        // Mantém o callback vivo até o fim do arraste (o view pode ser atualizado no meio).
        pendingDropCompletion = onSuccessfulDrop

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(text, forType: .string)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let preview = makeDragPreviewImage()
        let mouse = convert(event.locationInWindow, from: nil)
        let previewSize = preview.size
        // Centraliza a bolha sob o cursor (estilo Spokenly).
        let dragFrame = NSRect(
            x: mouse.x - previewSize.width * 0.45,
            y: mouse.y - previewSize.height * 0.55,
            width: previewSize.width,
            height: previewSize.height
        )
        draggingItem.setDraggingFrame(dragFrame, contents: preview)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let completion = pendingDropCompletion
        pendingDropCompletion = nil

        // Electron/Cursor etc. costumam aceitar o drop mas reportar `.none`.
        // Se soltou fora da barra, consideramos entrega (ou abandono) e fechamos.
        let acceptedByDestination = !operation.isEmpty
        let releasedOutsideBar: Bool = {
            guard let window else { return true }
            return !window.frame.insetBy(dx: -4, dy: -4).contains(screenPoint)
        }()

        guard acceptedByDestination || releasedOutsideBar else { return }

        DispatchQueue.main.async {
            completion?()
        }
    }

    /// Bolha compacta só com o texto — visual próximo ao Spokenly.
    private func makeDragPreviewImage() -> NSImage {
        let font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            .paragraphStyle: paragraph
        ]

        let maxTextWidth: CGFloat = 300
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxTextHeight = lineHeight * 2.15

        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: maxTextHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        let padX: CGFloat = 16
        let padY: CGFloat = 13
        let radius: CGFloat = 12
        let bubbleW = min(maxTextWidth, max(140, ceil(textBounds.width))) + padX * 2
        let bubbleH = min(maxTextHeight, max(lineHeight, ceil(textBounds.height))) + padY * 2

        let shadowBlur: CGFloat = 14
        let margin = shadowBlur + 6
        let imageSize = NSSize(width: bubbleW + margin * 2, height: bubbleH + margin * 2)

        return NSImage(size: imageSize, flipped: false) { _ in
            let bubble = NSRect(x: margin, y: margin, width: bubbleW, height: bubbleH)
            let path = NSBezierPath(roundedRect: bubble, xRadius: radius, yRadius: radius)

            // Sombra suave sob a bolha.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
            shadow.shadowBlurRadius = shadowBlur
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor(calibratedWhite: 0.08, alpha: 0.55).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Vidro escuro translúcido.
            NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.78).setFill()
            path.fill()

            // Borda fina clara.
            NSColor.white.withAlphaComponent(0.20).setStroke()
            path.lineWidth = 1
            path.stroke()

            let textRect = NSRect(
                x: bubble.minX + padX,
                y: bubble.minY + padY,
                width: bubbleW - padX * 2,
                height: bubbleH - padY * 2
            )
            (self.text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
    }
}
