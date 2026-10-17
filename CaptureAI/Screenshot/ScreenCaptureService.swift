import AppKit
import Foundation
import OSLog

/// Dispara a seleção de tela e devolve o arquivo capturado.
///
/// A seleção é nossa, não a do macOS: o seletor nativo (`screencapture -i`)
/// mostra só um crosshair, sem escurecer a tela, e essa confirmação visual de
/// "estou capturando, escolha a área" é o que se espera de uma ferramenta de
/// captura. O véu, as alças e a etiqueta de dimensões vivem no
/// `SelectionOverlayWindow`; aqui fica só o recorte da imagem.
@MainActor
final class ScreenCaptureService {
    enum CaptureResult {
        /// O usuário selecionou e o arquivo está em `url`.
        case captured(url: URL)
        /// Esc, ou clique sem arrasto.
        case cancelled
    }

    enum CaptureError: LocalizedError {
        case toolMissing
        case failed(status: Int32)

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "A ferramenta de captura do macOS não foi encontrada."
            case .failed(let status):
                return "A captura de tela falhou (código \(status))."
            }
        }
    }

    private static let toolPath = "/usr/sbin/screencapture"
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "screen-capture")
    private let fileManager: FileManager
    private let overlay = SelectionOverlayController()

    /// Impede duas seleções simultâneas — dois overlays nativos ao mesmo tempo
    /// deixam a tela num estado confuso e só o segundo responde ao Esc.
    private(set) var isCapturing = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Mostra o véu de seleção e captura a área escolhida.
    ///
    /// Grava num arquivo temporário em vez de direto na pasta final: enquanto a
    /// revisão não é confirmada, a captura ainda não é um arquivo que o usuário
    /// pediu para guardar. Cancelar na revisão não deve deixar lixo na pasta.
    func captureInteractively() async throws -> CaptureResult {
        guard fileManager.isExecutableFile(atPath: Self.toolPath) else {
            throw CaptureError.toolMissing
        }
        guard !isCapturing, !overlay.isPresenting else { return .cancelled }
        isCapturing = true
        defer { isCapturing = false }

        guard let region = await selectRegion() else { return .cancelled }

        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("captureai-\(UUID().uuidString).png")

        let status = await runTool(arguments: [
            "-x",  // sem o som de obturador: o app dá o próprio retorno visual
            "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
            destination.path,
        ])

        guard status == 0, fileManager.fileExists(atPath: destination.path) else {
            throw CaptureError.failed(status: status)
        }
        return .captured(url: destination)
    }

    /// Ponte entre o overlay (callback) e o async daqui.
    private func selectRegion() async -> CGRect? {
        await withCheckedContinuation { continuation in
            overlay.present { rect in
                continuation.resume(returning: rect)
            }
        }
    }

    /// Move a captura temporária para a pasta final, com nome por data.
    ///
    /// Se já existir um arquivo com o mesmo segundo, um sufixo numérico entra
    /// em cena: sobrescrever silenciosamente uma captura anterior seria perda
    /// de dado sem aviso.
    func persist(temporaryURL: URL, into directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        var candidate = directory.appendingPathComponent("captureai-\(stamp).png")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("captureai-\(stamp)-\(suffix).png")
            suffix += 1
        }

        try fileManager.moveItem(at: temporaryURL, to: candidate)
        return candidate
    }

    func discard(temporaryURL: URL) {
        try? fileManager.removeItem(at: temporaryURL)
    }

    /// Roda a ferramenta fora do MainActor e devolve o código de saída.
    private func runTool(arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Self.toolPath)
                process.arguments = arguments
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: -1)
                }
            }
        }
    }
}
