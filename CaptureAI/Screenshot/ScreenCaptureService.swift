import AppKit
import Foundation
import OSLog

/// Dispara a seleção de tela e devolve o arquivo capturado.
///
/// A seleção é a nativa do macOS (`screencapture -i`), não uma janela nossa.
/// Ela já entrega escurecimento, dimensões ao vivo, `Space` para arrastar a
/// seleção inteira, `Esc` para cancelar e `Ctrl` para mandar direto à área de
/// transferência — além de lidar com múltiplos monitores, escalas Retina e
/// Spaces, que é onde um overlay próprio gastaria a maior parte do esforço.
///
/// O que o nativo não faz — revisar, anotar, escolher destino — é o que a
/// janela de revisão acrescenta depois, já com a imagem em mãos.
@MainActor
final class ScreenCaptureService {
    enum CaptureResult {
        /// O usuário selecionou e o arquivo está em `url`.
        case captured(url: URL)
        /// O usuário segurou Ctrl: a imagem foi para a área de transferência.
        case copiedToPasteboard
        /// Esc, ou seleção de área nula.
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

    /// Impede duas seleções simultâneas — dois overlays nativos ao mesmo tempo
    /// deixam a tela num estado confuso e só o segundo responde ao Esc.
    private(set) var isCapturing = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Abre a seleção interativa e espera o usuário decidir.
    ///
    /// Grava num arquivo temporário em vez de direto na pasta final: enquanto a
    /// revisão não é confirmada, a captura ainda não é um arquivo que o usuário
    /// pediu para guardar. Cancelar na revisão não deve deixar lixo na pasta.
    func captureInteractively() async throws -> CaptureResult {
        guard fileManager.isExecutableFile(atPath: Self.toolPath) else {
            throw CaptureError.toolMissing
        }
        guard !isCapturing else { return .cancelled }
        isCapturing = true
        defer { isCapturing = false }

        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("captureai-\(UUID().uuidString).png")

        let status = await runTool(arguments: [
            "-i",   // seleção interativa
            "-s",   // só seleção por arrasto; evita cair no modo janela sem querer
            "-x",   // sem o som de obturador: o app dá o próprio retorno visual
            destination.path,
        ])

        // 1 é o código de "o usuário desistiu" (Esc). Não é erro.
        if status == 1 { return .cancelled }
        guard status == 0 else { throw CaptureError.failed(status: status) }

        // Com Ctrl segurado o conteúdo vai para a área de transferência e
        // nenhum arquivo é criado — é o atalho que o usuário já tem no dedo.
        guard fileManager.fileExists(atPath: destination.path) else {
            logger.notice("Captura enviada à área de transferência pelo atalho Ctrl.")
            return .copiedToPasteboard
        }

        return .captured(url: destination)
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
