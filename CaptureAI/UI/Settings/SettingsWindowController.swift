import AppKit
import SwiftUI

/// Janela de configurações via AppKit — mais confiável que `Settings` scene em Menu Bar apps.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private weak var settings: AppSettings?
    private var viewModel: SettingsViewModel?
    private var systemAppearanceObserver: NSObjectProtocol?

    /// Tamanho mínimo (= padrão ao abrir). O usuário só pode aumentar.
    private static let defaultContentSize = NSSize(width: 860, height: 620)

    /// Mostra (ou reusa) a janela de configurações.
    ///
    /// - Parameter onTranscriptionPolicyChanged: chamado quando modo teste,
    ///   backend local ou modo teste mudam — para liberar o modelo da memória.
    /// - Parameter onRecordingHUDStyleChanged: reaplica a barra flutuante na hora.
    /// - Parameter onDictationHotkeyChanged: re-registra o atalho global.
    /// - Parameter onHotkeyCaptureSessionChanged: pausa/retoma o atalho durante a captura.
    /// - Parameter onFieldDictationRequested: grava e devolve o texto a um campo do app.
    /// - Parameter onFieldDictationStopRequested: encerra essa gravação.
    func show(
        settings: AppSettings,
        historyStore: TranscriptionHistoryStore = .shared,
        screenshotStore: ScreenshotStore? = nil,
        captureCoordinator: ScreenCaptureCoordinator? = nil,
        tab: SettingsTab? = nil,
        onCaptureHotkeyChanged: @escaping () -> Void = {},
        onTranscriptionPolicyChanged: @escaping () -> Void = {},
        onRecordingHUDStyleChanged: @escaping () -> Void = {},
        onDictationHotkeyChanged: @escaping () -> Void = {},
        onHotkeyCaptureSessionChanged: @escaping (Bool) -> Void = { _ in },
        onFieldDictationRequested: @escaping (Bool, @escaping (String?) -> Void) -> Void = { _, done in done(nil) },
        onFieldDictationStopRequested: @escaping () -> Void = {},
        onFieldDictationCancelRequested: @escaping () -> Void = {},
        onHistoryAudioPlayRequested: @escaping (UUID, URL) throws -> Void = { _, _ in },
        onHistoryAudioStopRequested: @escaping () -> Void = {},
        playingHistoryEntryID: @escaping () -> UUID? = { nil }
    ) {
        self.settings = settings
        settings.refreshAPIKeyStatus()

        let applyTheme: () -> Void = { [weak self] in
            self?.applyAppearanceTheme()
        }

        if let viewModel {
            viewModel.onTranscriptionPolicyChanged = onTranscriptionPolicyChanged
            viewModel.onAppearanceThemeChanged = applyTheme
            viewModel.onRecordingHUDStyleChanged = onRecordingHUDStyleChanged
            viewModel.onDictationHotkeyChanged = onDictationHotkeyChanged
            viewModel.onCaptureHotkeyChanged = onCaptureHotkeyChanged
            viewModel.onHotkeyCaptureSessionChanged = onHotkeyCaptureSessionChanged
            viewModel.onFieldDictationRequested = onFieldDictationRequested
            viewModel.onFieldDictationStopRequested = onFieldDictationStopRequested
            viewModel.onFieldDictationCancelRequested = onFieldDictationCancelRequested
            viewModel.onHistoryAudioPlayRequested = onHistoryAudioPlayRequested
            viewModel.onHistoryAudioStopRequested = onHistoryAudioStopRequested
            viewModel.playingHistoryEntryID = playingHistoryEntryID
        } else {
            let viewModel = SettingsViewModel(
                settings: settings,
                historyStore: historyStore,
                screenshotStore: screenshotStore,
                captureCoordinator: captureCoordinator,
                onCaptureHotkeyChanged: onCaptureHotkeyChanged,
                onTranscriptionPolicyChanged: onTranscriptionPolicyChanged,
                onAppearanceThemeChanged: applyTheme,
                onRecordingHUDStyleChanged: onRecordingHUDStyleChanged,
                onDictationHotkeyChanged: onDictationHotkeyChanged,
                onHotkeyCaptureSessionChanged: onHotkeyCaptureSessionChanged,
                onFieldDictationRequested: onFieldDictationRequested,
                onFieldDictationStopRequested: onFieldDictationStopRequested,
                onFieldDictationCancelRequested: onFieldDictationCancelRequested,
                onHistoryAudioPlayRequested: onHistoryAudioPlayRequested,
                onHistoryAudioStopRequested: onHistoryAudioStopRequested,
                playingHistoryEntryID: playingHistoryEntryID
            )
            self.viewModel = viewModel
            let root = SettingsView(viewModel: viewModel)
            let hosting = NSHostingController(rootView: root)

            let window = NSWindow(contentViewController: hosting)
            window.title = "Configurações — CaptureAI"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Barra de título some no fundo translúcido; o título fica na própria tela.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.setContentSize(Self.defaultContentSize)
            window.minSize = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)
            ).size
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = WindowCloseObserver.shared
            WindowCloseObserver.shared.onClose = { [weak self] in
                self?.handleClosed()
            }
            self.window = window
            viewModel.hostWindow = window
            startObservingSystemAppearance()
        }

        // Reuso: garante referência atualizada da janela.
        viewModel?.hostWindow = window
        // Vale também na reabertura: quem pediu uma aba específica quer ela,
        // não a que ficou selecionada da última vez.
        if let tab {
            viewModel?.selectedTab = tab
        }
        enforceMinimumWindowSize()
        applyAppearanceTheme()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Garante o tamanho padrão ao abrir e impede encolher abaixo dele.
    private func enforceMinimumWindowSize() {
        guard let window else { return }
        window.setContentSize(Self.defaultContentSize)
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)
        ).size
    }

    /// Aplica Sistema / Claro / Escuro na janela AppKit.
    private func applyAppearanceTheme() {
        let theme = AppAppearanceTheme(rawValue: settings?.appearanceTheme ?? "") ?? .system
        // Aparência concreta: `nil` após forçar claro/escuro não reaplica o
        // tema do sistema até a janela perder o foco.
        window?.appearance = theme.resolvedNSAppearance()
        window?.contentView?.appearance = nil
        window?.displayIfNeeded()
    }

    private func startObservingSystemAppearance() {
        guard systemAppearanceObserver == nil else { return }
        systemAppearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.handleSystemAppearanceChanged()
            }
        }
    }

    private func handleClosed() {
        let hasOtherWindows = NSApp.windows.contains { candidate in
            candidate !== window
                && candidate.isVisible
                && candidate.canBecomeKey
                && candidate.frame.width > 80
        }
        if !hasOtherWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    deinit {
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default.removeObserver(systemAppearanceObserver)
        }
    }
}

/// Observa o fechamento da janela de configurações.
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    static let shared = WindowCloseObserver()
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
