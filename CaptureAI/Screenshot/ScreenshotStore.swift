import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog

/// Uma captura de tela salva em disco.
///
/// Diferente do histórico de texto, aqui o disco é a fonte da verdade: as
/// imagens vivem numa pasta que o usuário escolhe, abre no Finder e pode
/// mexer por fora. Por isso não há JSON de índice — a lista é montada lendo a
/// pasta, e um arquivo apagado no Finder simplesmente deixa de aparecer.
struct ScreenshotEntry: Identifiable, Equatable, Sendable {
    let id: URL
    var url: URL { id }
    let createdAt: Date
    let byteCount: Int
    let pixelSize: CGSize?

    var fileName: String { url.lastPathComponent }

    /// Rótulo curto com as dimensões (ex.: `1280 × 720`).
    var resolutionLabel: String? {
        guard let pixelSize, pixelSize.width > 0 else { return nil }
        return "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }
}

/// Lista e administra a pasta de capturas.
@Observable
@MainActor
final class ScreenshotStore {
    static let shared = ScreenshotStore()

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "screenshots")
    private let fileManager: FileManager
    private let settings: AppSettings?

    private(set) var entries: [ScreenshotEntry] = []

    init(fileManager: FileManager = .default, settings: AppSettings? = nil) {
        self.fileManager = fileManager
        self.settings = settings
    }

    /// Pasta padrão quando o usuário não escolheu outra: `~/Documentos/CaptureAI`.
    static var defaultDirectoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent("CaptureAI", isDirectory: true)
    }

    /// Onde as capturas são gravadas agora.
    var directoryURL: URL {
        let url = settings?.screenshotDirectoryURL ?? Self.defaultDirectoryURL
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Relê a pasta. Barato o bastante para rodar ao abrir a aba.
    func reload() {
        let directory = directoryURL
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }

        let supported: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic", "pdf"]
        entries = urls
            .filter { supported.contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return ScreenshotEntry(
                    id: url,
                    createdAt: values?.creationDate ?? .distantPast,
                    byteCount: values?.fileSize ?? 0,
                    pixelSize: Self.pixelSize(of: url)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Dimensões sem decodificar a imagem inteira — lê só o cabeçalho.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    func delete(_ entry: ScreenshotEntry) {
        do {
            try fileManager.removeItem(at: entry.url)
            entries.removeAll { $0.id == entry.id }
        } catch {
            logger.error("Falha ao apagar captura: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Esvazia a pasta de capturas.
    ///
    /// Só remove os arquivos de imagem que listamos: a pasta é do usuário e
    /// pode ter outra coisa dentro que não nos cabe apagar.
    func deleteAll() {
        let removed = entries.count
        for entry in entries {
            try? fileManager.removeItem(at: entry.url)
        }
        entries = []
        logger.notice("Capturas apagadas (\(removed, privacy: .public) arquivos).")
    }

    func revealInFinder(_ entry: ScreenshotEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func openDirectoryInFinder() {
        NSWorkspace.shared.open(directoryURL)
    }

    /// Coloca a imagem na área de transferência.
    func copyToPasteboard(_ entry: ScreenshotEntry) {
        guard let image = NSImage(contentsOf: entry.url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

/// Estado da permissão de Gravação de Tela.
///
/// O macOS exige essa autorização para qualquer captura que inclua conteúdo de
/// outras janelas. Sem ela, a seleção abre mas a imagem sai com o papel de
/// parede no lugar das janelas — uma falha silenciosa que confunde muito mais
/// do que um aviso antecipado.
enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Pede a permissão. Na primeira vez o macOS mostra o diálogo; depois, só
    /// abrir os Ajustes resolve, porque o sistema não pergunta duas vezes.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!
        NSWorkspace.shared.open(url)
    }
}
