import AppKit
import SwiftUI

/// Controla o painel flutuante de feedback sem roubar o foco do app ativo.
/// Posição fixa (centro inferior). Recebe cliques para pause e barra de resgate.
@MainActor
final class RecordingOverlayController {
    private var panel: OverlayPanel?
    private var hostingView: OverlayHostingView<RecordingOverlay>?
    private var appState: AppState?
    private var currentSize: CGSize = RecordingOverlay.recordingBarSize

    func sync(with appState: AppState) {
        self.appState = appState

        let style = RecordingHUDStyle(rawValue: appState.settings.recordingHUDStyle) ?? .moderno
        let isRescue = appState.recordingState == .awaitingManualInsert
            && !(appState.pendingDictationText ?? "").isEmpty

        // Resgate sempre aparece — mesmo com HUD “Nenhuma”.
        if isRescue {
            show(using: appState, size: RecordingOverlay.rescueBarSize, cornerRadius: 18)
            return
        }

        // Reprodução também ignora o HUD "Nenhuma": o usuário clicou em tocar e
        // precisa de onde pausar e fechar. Sem barra, o áudio tocaria sem
        // controle nenhum.
        if appState.playback.session != nil {
            show(
                using: appState,
                size: RecordingOverlay.recordingBarSize,
                cornerRadius: RecordingOverlay.recordingBarSize.height / 2,
                // A janela de configurações continua em foco atrás.
                takesKey: false
            )
            return
        }

        // Captura para um campo do app aparece mesmo com HUD "Nenhuma": ali o
        // usuário clicou num microfone e precisa ver que está gravando — e como
        // parar. Sem barra, o clique não teria retorno nenhum.
        guard style.showsFloatingBar || appState.isCapturingForField else {
            hide()
            return
        }

        switch appState.recordingState {
        case .recording, .paused, .error:
            show(
                using: appState,
                size: RecordingOverlay.recordingBarSize,
                cornerRadius: RecordingOverlay.recordingBarSize.height / 2,
                // Virar key tiraria o foco do campo que disparou a gravação, e
                // o arraste que exige isso não interessa nesse fluxo.
                takesKey: !appState.isCapturingForField
            )
        case .idle, .transcribing, .inserting, .success, .awaitingManualInsert:
            hide()
        }
    }

    private func show(
        using appState: AppState,
        size: CGSize,
        cornerRadius: CGFloat,
        takesKey: Bool = true
    ) {
        currentSize = size

        if panel == nil {
            let built = makePanel(appState: appState, size: size)
            panel = built.panel
            hostingView = built.hosting
        } else if let hostingView {
            hostingView.rootView = RecordingOverlay(appState: appState)
            hostingView.frame = NSRect(origin: .zero, size: size)
        }

        guard let panel else { return }
        panel.setContentSize(size)
        applyMask(to: panel, cornerRadius: cornerRadius)
        panel.ignoresMouseEvents = false
        placeFixed(panel, size: size)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Precisa ser key para o arraste AppKit receber mouseDown com confiabilidade.
        if takesKey {
            panel.makeKey()
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(appState: AppState, size: CGSize) -> (panel: OverlayPanel, hosting: OverlayHostingView<RecordingOverlay>) {
        let hostingView = OverlayHostingView(rootView: RecordingOverlay(appState: appState))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        applyMask(to: panel, cornerRadius: size.height / 2)

        return (panel, hostingView)
    }

    private func applyMask(to panel: OverlayPanel, cornerRadius: CGFloat) {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.cornerRadius = cornerRadius
        content.layer?.masksToBounds = true
        content.layer?.isOpaque = false
    }

    private func placeFixed(_ panel: OverlayPanel, size: CGSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.minY + 36
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Painel flutuante que pode ser key sem virar main (necessário para arrastar texto).
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting que aceita o primeiro clique sem exigir ativar o app antes.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
