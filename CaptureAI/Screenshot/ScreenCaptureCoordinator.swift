import AppKit
import Observation
import OSLog

/// Liga o atalho ao editor de captura e ao destino final.
///
/// O serviço não sabe onde as imagens vão parar, e o store só descobre o
/// arquivo quando ele já está na pasta: quem decide copiar ou gravar é este
/// coordenador.
@Observable
@MainActor
final class ScreenCaptureCoordinator {
    private let service: ScreenCaptureService
    private let store: ScreenshotStore
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "screen-capture")

    /// Última mensagem para a UI (sucesso ou falha), consumida pela aba.
    var lastMessage: String?

    init(settings: AppSettings, store: ScreenshotStore, service: ScreenCaptureService? = nil) {
        self.store = store
        self.service = service ?? ScreenCaptureService()
    }

    /// Começa uma captura. Chamado pelo atalho global e pelo botão da aba.
    func beginCapture() {
        Task { await performCapture() }
    }

    private func performCapture() async {
        do {
            switch try await service.captureInteractively() {
            case .cancelled:
                return
            case .copy(let image, let scale):
                copy(image, scale: scale)
            case .save(let image, _):
                save(image)
            }
        } catch {
            logger.error("Captura falhou: \(error.localizedDescription, privacy: .public)")
            lastMessage = error.localizedDescription
        }
    }

    /// Vai para a área de transferência com o tamanho em pontos.
    ///
    /// Sem o tamanho, a imagem colada num documento sairia com o dobro do
    /// tamanho em telas Retina, porque o app que recebe leria os pixels como
    /// pontos.
    private func copy(_ image: CGImage, scale: CGFloat) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
        lastMessage = "Captura copiada."
    }

    private func save(_ image: CGImage) {
        do {
            let url = try write(image, into: store.directoryURL)
            store.reload()
            lastMessage = "Salva em \(url.lastPathComponent)."
        } catch {
            logger.error("Falha ao salvar captura: \(error.localizedDescription, privacy: .public)")
            lastMessage = "Não foi possível salvar a captura."
        }
    }

    /// Grava o PNG com nome por data, sem sobrescrever nada que já exista.
    private func write(_ image: CGImage, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.timestamp()
        var candidate = directory.appendingPathComponent("captureai-\(stamp).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("captureai-\(stamp)-\(suffix).png")
            suffix += 1
        }

        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: candidate, options: [.atomic])
        return candidate
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
