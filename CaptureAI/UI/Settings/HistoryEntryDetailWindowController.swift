import AppKit
import SwiftUI

/// Janela nativa (com X de fechar) para ler uma transcrição completa.
@MainActor
final class HistoryEntryDetailWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private static let contentSize = NSSize(width: 520, height: 360)

    func present(
        entry: TranscriptionHistoryEntry,
        dateLabel: String,
        durationLabel: String?,
        appearance: NSAppearance?,
        preferredColorScheme: ColorScheme,
        relativeTo parentWindow: NSWindow?,
        onCopy: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        dismiss()

        let root = HistoryEntryDetailContent(
            entry: entry,
            dateLabel: dateLabel,
            durationLabel: durationLabel,
            onCopy: onCopy,
            onDelete: { [weak self] in
                onDelete()
                self?.dismiss()
            }
        )
        .preferredColorScheme(preferredColorScheme)
        .frame(minWidth: 440, minHeight: 280)

        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: Self.contentSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Transcrição"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.contentSize)
        window.minSize = NSSize(width: 420, height: 260)
        window.appearance = appearance
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        Self.center(window, over: parentWindow)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cleanup()
            }
        }

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
        cleanup()
    }

    private func cleanup() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window = nil
    }

    /// Centraliza sobre a janela de configurações (não no meio da tela).
    private static func center(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent else {
            window.center()
            return
        }

        let size = window.frame.size
        var origin = NSPoint(
            x: parent.frame.midX - size.width / 2,
            y: parent.frame.midY - size.height / 2
        )

        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }

        window.setFrameOrigin(origin)
    }
}

/// Conteúdo translúcido da janela de detalhe do histórico.
private struct HistoryEntryDetailContent: View {
    let entry: TranscriptionHistoryEntry
    let dateLabel: String
    let durationLabel: String?
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var didCopy = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 36)
                    .padding(.bottom, 16)
            }

            Divider()
                .overlay(SettingsTheme.divider(colorScheme))

            HStack(spacing: 10) {
                Text(metaLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))

                Spacer(minLength: 8)

                Button {
                    onCopy()
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1_400))
                        didCopy = false
                    }
                } label: {
                    Text(didCopy ? "Copiado" : "Copiar")
                        .foregroundStyle(
                            didCopy
                                ? SettingsTheme.accent
                                : SettingsTheme.primaryLabel(colorScheme).opacity(0.9)
                        )
                }
                .buttonStyle(HistoryCopyTextButtonStyle())
                .animation(.easeOut(duration: 0.15), value: didCopy)

                Button("Excluir", action: onDelete)
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsBackground())
    }

    private var metaLabel: String {
        if let durationLabel {
            return "\(dateLabel) – \(durationLabel)"
        }
        return dateLabel
    }
}

/// Botão de texto do rodapé (Copiar/Copiado) sem forçar a cor do GhostButton.
private struct HistoryCopyTextButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                Capsule().fill(SettingsTheme.ghostFill(colorScheme, pressed: configuration.isPressed))
            }
            .overlay {
                Capsule().strokeBorder(SettingsTheme.ghostStroke(colorScheme), lineWidth: SettingsTheme.hairline)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
