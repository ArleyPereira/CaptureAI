import AppKit
import Quartz

/// Abre as capturas no Quick Look, em tela cheia — o mesmo visualizador do
/// espaço no Finder.
///
/// Nativo em vez de uma janela própria: zoom, navegação entre imagens pelas
/// setas, Esc para sair e o botão de compartilhar já vêm prontos e se
/// comportam como a pessoa espera de qualquer imagem no macOS.
@MainActor
final class ScreenshotPreviewController: NSObject {
    static let shared = ScreenshotPreviewController()

    private var urls: [URL] = []

    /// Mostra `urls` começando por `index`. As demais ficam a uma seta de
    /// distância, na mesma ordem da lista.
    func show(_ urls: [URL], startingAt index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !panel.isInFullScreenMode {
            panel.enterFullScreenMode(nil, withOptions: nil)
        }
    }
}

extension ScreenshotPreviewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }
    }
}
