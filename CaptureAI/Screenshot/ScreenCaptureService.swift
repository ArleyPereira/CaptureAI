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

    /// Modo pedido antes de o editor terminar de abrir — o W segurado com o
    /// Print Screen chega enquanto a tela ainda está sendo congelada.
    private var pendingMode: CaptureMode?

    /// Pede o modo janela. Vale para o editor aberto ou para o que está abrindo.
    func requestWindowMode() {
        if editor.isPresenting {
            editor.setMode(.window)
        } else if isCapturing {
            pendingMode = .window
        }
    }

    /// O que chega ao coordenador: sempre uma imagem pronta e o que fazer com ela.
    enum Outcome {
        case copy(CGImage, scale: CGFloat)
        case save(CGImage, scale: CGFloat)
        /// Captura de janela: vai para a área de transferência e ganha a
        /// miniatura flutuante — é o único modo sem barra de ações na tela.
        case window(CGImage, scale: CGFloat)
        case cancelled
    }

    /// Há captura congelando ou editor aberto.
    var isBusy: Bool { isCapturing || editor.isPresenting }

    func captureInteractively(mode: CaptureMode = .area) async throws -> Outcome {
        guard !isCapturing, !editor.isPresenting else { return .cancelled }

        guard ScreenRecordingPermission.isGranted else {
            // Na primeira vez o macOS mostra o pedido; depois, só os Ajustes.
            ScreenRecordingPermission.request()
            throw CaptureError.permissionDenied
        }

        isCapturing = true
        defer {
            isCapturing = false
            pendingMode = nil
        }
        // Tirada antes do congelamento: depois dele o editor já estaria por cima.
        let capturable = CapturableWindow.onScreen()

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
            editor.present(
                frozen,
                mode: pendingMode ?? mode,
                capturableWindows: capturable
            ) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .copy(let image, let scale):
            logger.notice("Captura copiada: \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
            return .copy(image, scale: scale)
        case .save(let image, let scale):
            logger.notice("Captura para salvar: \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
            return .save(image, scale: scale)
        case .window(let window, let screen):
            let image = try await WindowCaptureComposer.compose(window, on: screen)
            logger.notice("Janela capturada (\(window.ownerName, privacy: .public)): \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
            return .window(image, scale: screen.backingScaleFactor)
        case .cancelled:
            logger.notice("Captura cancelada.")
            return .cancelled
        }
    }
}
