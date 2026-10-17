import AppKit
import Foundation
import OSLog

/// Congela a tela e abre o editor de captura.
///
/// O fluxo inteiro acontece sobre a tela, sem janela intermediária: o atalho
/// tira uma foto de cada monitor, o editor mostra essa foto escurecida, e a
/// pessoa seleciona, ajusta, anota e decide ali mesmo — copiar ou salvar.
@MainActor
final class ScreenCaptureService {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case freezeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Conceda a permissão de Gravação de Tela ao CaptureAI para capturar a tela."
            case .freezeFailed(let reason):
                return "Não foi possível capturar a tela (\(reason))."
            }
        }
    }

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "screen-capture")
    private let editor = CaptureEditorController()

    /// Impede abrir um segundo editor por cima do primeiro.
    private(set) var isCapturing = false

    func captureInteractively() async throws -> CaptureEditorResult {
        guard !isCapturing, !editor.isPresenting else { return .cancelled }

        guard ScreenRecordingPermission.isGranted else {
            // Na primeira vez o macOS mostra o pedido; depois, só os Ajustes.
            ScreenRecordingPermission.request()
            throw CaptureError.permissionDenied
        }

        isCapturing = true
        defer { isCapturing = false }

        let frozen: [ScreenFreezer.FrozenScreen]
        do {
            frozen = try await ScreenFreezer.freezeAll()
        } catch {
            logger.error("Falha ao congelar a tela: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.freezeFailed(error.localizedDescription)
        }
        guard !frozen.isEmpty else { throw CaptureError.freezeFailed("nenhum monitor") }
        logger.notice("Tela congelada: \(frozen.count, privacy: .public) monitor(es).")

        let result = await withCheckedContinuation { continuation in
            editor.present(frozen) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .copy(let image, _): logger.notice("Captura copiada: \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
        case .save(let image, _): logger.notice("Captura para salvar: \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
        case .cancelled: logger.notice("Captura cancelada.")
        }
        return result
    }
}
