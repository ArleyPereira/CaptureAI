import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

/// Uma captura de tela em disco.
///
/// Diferente do histórico de texto, aqui o disco é a fonte da verdade: toda
/// captura salva vira um arquivo na pasta que o usuário escolheu, e a lista é
/// montada lendo essa pasta. Copiar não grava nada. Não há JSON de índice: um
/// arquivo apagado no Finder simplesmente deixa de aparecer.
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

    /// Grava uma captura na pasta do usuário e devolve onde ela ficou.
    @discardableResult
    func save(png data: Data) throws -> URL {
        let destination = Self.uniqueURL(in: directoryURL, fileManager: fileManager)
        try data.write(to: destination, options: [.atomic])
        reload()
        return destination
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

    /// Relê a pasta. Barato o bastante para rodar ao abrir a aba.
    func reload() {
        entries = imageFiles(in: directoryURL)
            .map { file in
                ScreenshotEntry(
                    id: file.url,
                    createdAt: file.date,
                    byteCount: file.size,
                    pixelSize: Self.pixelSize(of: file.url)
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

    /// Manda a captura para a Lixeira e devolve onde ela foi parar.
    ///
    /// Lixeira em vez de apagar de vez: o "desfazer" só precisa trazer o
    /// arquivo de volta, e mesmo depois de o aviso sumir a captura continua
    /// recuperável pelo Finder, como qualquer arquivo excluído no macOS.
    @discardableResult
    func delete(_ entry: ScreenshotEntry) -> URL? {
        do {
            var trashed: NSURL?
            try fileManager.trashItem(at: entry.url, resultingItemURL: &trashed)
            entries.removeAll { $0.id == entry.id }
            return trashed as URL?
        } catch {
            logger.error("Falha ao excluir captura: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Tira da Lixeira uma captura excluída e a põe de volta onde estava.
    func restore(trashed: URL, to original: URL) {
        do {
            try fileManager.moveItem(at: trashed, to: original)
            reload()
        } catch {
            logger.error("Falha ao restaurar captura: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apaga todas as capturas da lista.
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

    /// Coloca a captura na área de transferência como o próprio arquivo.
    ///
    /// Vai a URL do arquivo e o PNG dele, sem reprocessar. Com a URL, colar
    /// no Finder copia o arquivo original, com nome e formato; apps que
    /// querem a imagem leem o PNG. Um `NSImage` aqui seria serializado como
    /// TIFF, e o Finder colaria um `.tiff`.
    func copyToPasteboard(_ entry: ScreenshotEntry) {
        guard let data = try? Data(contentsOf: entry.url) else { return }
        let item = NSPasteboardItem()
        item.setString(entry.url.absoluteString, forType: .fileURL)
        item.setData(data, forType: Self.pasteboardType(for: entry.url))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private static func pasteboardType(for url: URL) -> NSPasteboard.PasteboardType {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "tiff": return .tiff
        case "pdf": return .pdf
        default: return NSPasteboard.PasteboardType(UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.image")
        }
    }

    /// Coloca uma captura recém-feita na área de transferência, em PNG.
    ///
    /// O PNG leva a densidade da tela (144 dpi numa Retina): apps que a
    /// respeitam colam a imagem no tamanho em pontos, e não no dobro. O
    /// sistema ainda oferece TIFF a quem só aceita TIFF.
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) {
        guard let data = png(image, scale: scale) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// PNG com a densidade da tela gravada no arquivo.
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
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
