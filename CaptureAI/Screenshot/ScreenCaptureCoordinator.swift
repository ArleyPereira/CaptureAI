import AppKit
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Liga o atalho à seleção, à revisão e ao destino final.
///
/// Existe para que nenhuma das partes precise conhecer as outras: o serviço de
/// captura não sabe o que é uma janela de revisão, a janela não sabe onde o
/// arquivo será gravado, e o store só descobre o arquivo quando ele já está no
/// lugar certo.
@Observable
@MainActor
final class ScreenCaptureCoordinator {
    private let service: ScreenCaptureService
    private let store: ScreenshotStore
    private let settings: AppSettings
    private let reviewWindow = ScreenshotReviewWindowController()
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "screen-capture")

    /// Última mensagem para a UI (sucesso ou falha), consumida pela aba.
    var lastMessage: String?

    init(settings: AppSettings, store: ScreenshotStore, service: ScreenCaptureService? = nil) {
        self.settings = settings
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

            case .captured(let temporaryURL):
                guard let image = NSImage(contentsOf: temporaryURL) else {
                    service.discard(temporaryURL: temporaryURL)
                    lastMessage = "Não foi possível ler a imagem capturada."
                    return
                }
                presentReview(image: image, temporaryURL: temporaryURL)
            }
        } catch {
            logger.error("Captura falhou: \(error.localizedDescription, privacy: .public)")
            lastMessage = error.localizedDescription
        }
    }

    private var theme: AppAppearanceTheme {
        AppAppearanceTheme(rawValue: settings.appearanceTheme) ?? .system
    }

    private func presentReview(image: NSImage, temporaryURL: URL) {
        reviewWindow.present(
            image: image,
            appearance: theme.resolvedNSAppearance(),
            preferredColorScheme: theme.resolvedColorScheme()
        ) { [weak self] decision in
            guard let self else { return }
            // O temporário some em qualquer saída: ou virou arquivo na pasta
            // final, ou o usuário desistiu dele.
            defer { self.service.discard(temporaryURL: temporaryURL) }

            switch decision {
            case .discard:
                return
            case .copy(let edited):
                self.copy(edited)
            case .save(let edited):
                self.save(edited, to: self.store.directoryURL)
            }
        }
    }

    private func copy(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        lastMessage = "Captura copiada."
    }

    private func save(_ image: NSImage, to directory: URL) {
        do {
            let url = try write(image, into: directory)
            store.reload()
            lastMessage = "Salva em \(url.lastPathComponent)."
        } catch {
            logger.error("Falha ao salvar captura: \(error.localizedDescription, privacy: .public)")
            lastMessage = "Não foi possível salvar a captura."
        }
    }

    private func write(_ image: NSImage, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var candidate = directory.appendingPathComponent(Self.defaultFileName())
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stamp = Self.timestamp()
            candidate = directory.appendingPathComponent("captureai-\(stamp)-\(suffix).png")
            suffix += 1
        }

        guard let data = data(from: image) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: candidate, options: [.atomic])
        return candidate
    }

    /// PNG na resolução real da imagem.
    ///
    /// Passa pelo `CGImage` em vez de usar `tiffRepresentation` direto porque
    /// numa tela Retina o `NSImage` reporta pontos, e gravar a partir dele
    /// devolveria metade dos pixels capturados.
    private func data(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        return rep.representation(using: .png, properties: [:])
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func defaultFileName() -> String {
        "captureai-\(timestamp()).png"
    }
}
