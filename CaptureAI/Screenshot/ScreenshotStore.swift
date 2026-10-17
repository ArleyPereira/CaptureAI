import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog

/// Uma captura de tela em disco.
///
/// Diferente do histórico de texto, aqui o disco é a fonte da verdade, e a
/// lista junta duas pastas: a que o usuário escolheu, com o que ele salvou, e
/// uma interna do app, com o que ele só copiou. Não há JSON de índice — um
/// arquivo apagado no Finder simplesmente deixa de aparecer.
struct ScreenshotEntry: Identifiable, Equatable, Sendable {
    let id: URL
    var url: URL { id }
    let createdAt: Date
    let byteCount: Int
    let pixelSize: CGSize?
    /// Está na pasta do usuário (foi salva), e não só no histórico de cópias.
    let isSaved: Bool

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

    /// Capturas que foram só copiadas.
    ///
    /// A área de transferência guarda uma imagem por vez e não deixa rastro;
    /// sem esta pasta, toda captura copiada sumiria da lista assim que outra
    /// coisa fosse copiada. Fica no Application Support porque é um
    /// histórico do app, não um arquivo que o usuário pediu para guardar.
    var historyDirectoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let url = base
            .appendingPathComponent("CaptureAI", isDirectory: true)
            .appendingPathComponent("Copied Captures", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Teto do histórico de cópias. Capturas de tela pesam ~1 MB cada; as
    /// salvas não entram na conta, porque essas o usuário quis guardar.
    static let maximumCopiedCaptures = 100

    /// Registra uma captura copiada e devolve onde ela ficou.
    @discardableResult
    func recordCopied(png data: Data) -> URL? {
        let url = Self.uniqueURL(in: historyDirectoryURL, fileManager: fileManager)
        do {
            try data.write(to: url, options: [.atomic])
            trimCopiedHistory()
            reload()
            return url
        } catch {
            logger.error("Falha ao registrar captura copiada: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Grava uma captura na pasta do usuário.
    ///
    /// Se ela já estava no histórico de cópias, o arquivo é **movido** em vez
    /// de gravado de novo: copiar e depois salvar a mesma captura tem que
    /// deixar um item só na lista, não dois iguais.
    @discardableResult
    func save(png data: Data, replacingCopied copied: URL? = nil) throws -> URL {
        let destination = Self.uniqueURL(in: directoryURL, fileManager: fileManager)
        if let copied, fileManager.fileExists(atPath: copied.path) {
            try fileManager.moveItem(at: copied, to: destination)
        } else {
            try data.write(to: destination, options: [.atomic])
        }
        reload()
        return destination
    }

    private func trimCopiedHistory() {
        let copied = imageFiles(in: historyDirectoryURL)
            .sorted { $0.date > $1.date }
        for old in copied.dropFirst(Self.maximumCopiedCaptures) {
            try? fileManager.removeItem(at: old.url)
        }
    }

    private static func uniqueURL(in directory: URL, fileManager: FileManager) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = directory.appendingPathComponent("captureai-\(stamp).png")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("captureai-\(stamp)-\(suffix).png")
            suffix += 1
        }
        return candidate
    }

    /// Onde as capturas são gravadas agora.
    var directoryURL: URL {
        let url = settings?.screenshotDirectoryURL ?? Self.defaultDirectoryURL
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Relê as duas pastas. Barato o bastante para rodar ao abrir a aba.
    func reload() {
        let saved = imageFiles(in: directoryURL).map { ($0, true) }
        let copied = imageFiles(in: historyDirectoryURL).map { ($0, false) }
        entries = (saved + copied)
            .map { file, isSaved in
                ScreenshotEntry(
                    id: file.url,
                    createdAt: file.date,
                    byteCount: file.size,
                    pixelSize: Self.pixelSize(of: file.url),
                    isSaved: isSaved
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private struct ImageFile {
        let url: URL
        let date: Date
        let size: Int
    }

    private func imageFiles(in directory: URL) -> [ImageFile] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let supported: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic", "pdf"]
        return urls
            .filter { supported.contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return ImageFile(url: url, date: values?.creationDate ?? .distantPast, size: values?.fileSize ?? 0)
            }
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

    /// Apaga todas as capturas da lista — salvas e copiadas.
    ///
    /// Só remove os arquivos de imagem que listamos: a pasta de capturas é do
    /// usuário e pode ter outra coisa dentro que não nos cabe apagar.
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
