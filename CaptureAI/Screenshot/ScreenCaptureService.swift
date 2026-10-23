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

    /// Tela inteira pedida enquanto a tela ainda estava sendo congelada.
    private var pendingFullScreen = false

    /// Pede a tela inteira para o editor aberto ou o que está abrindo.
    func requestFullScreen() {
        if editor.isPresenting {
            editor.captureFullScreen()
        } else if isCapturing {
            pendingFullScreen = true
        }
    }

    /// Tela inteira direto, sem passar pelo editor: o monitor onde está o
    /// mouse, com todas as janelas como estão.
    func captureFullScreen() async throws -> Outcome {
        guard !isCapturing, !editor.isPresenting else { return .cancelled }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.request()
            throw CaptureError.permissionDenied
        }
        isCapturing = true
        defer { isCapturing = false }

        let frozen: [ScreenFreezer.FrozenScreen]
        do {
            frozen = try await ScreenFreezer.freezeAll()
        } catch {
            throw CaptureError.freezeFailed(error.localizedDescription)
        }
        guard let shot = Self.screenUnderMouse(in: frozen) else { throw CaptureError.freezeFailed("nenhum monitor") }
        logger.notice("Tela inteira: \(shot.image.width, privacy: .public)×\(shot.image.height, privacy: .public) px.")
        return .thumbnail(shot.image, scale: shot.screen.backingScaleFactor)
    }

    private static func screenUnderMouse(in frozen: [ScreenFreezer.FrozenScreen]) -> ScreenFreezer.FrozenScreen? {
        let mouse = NSEvent.mouseLocation
        return frozen.first { $0.screen.frame.contains(mouse) } ?? frozen.first
    }

    /// Pede um modo (janela ou texto). Vale para o editor aberto ou para o
    /// que está abrindo.
    func requestMode(_ mode: CaptureMode) {
        if editor.isPresenting {
            editor.setMode(mode)
        } else if isCapturing {
            pendingMode = mode
        }
    }

    /// O que chega ao coordenador: sempre uma imagem pronta e o que fazer com ela.
    enum Outcome {
        case copy(CGImage, scale: CGFloat)
        case save(CGImage, scale: CGFloat)
        /// Janela ou tela inteira: ganha a miniatura flutuante, onde se decide
        /// entre copiar e salvar — são os modos sem barra de ações na tela.
        case thumbnail(CGImage, scale: CGFloat)
        /// Recorte do modo texto, para reconhecer o texto.
        case text(CGImage, scale: CGFloat)
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
            pendingFullScreen = false
        }
        // Tirada antes do congelamento: depois dele o editor já estaria por cima.
        let capturable = CapturableWindow.onScreen()

        // A janela sob o mouse é fotografada junto com o congelamento, antes
        // de o editor cobrir a tela e tirar o hover dela.
        async let early = Self.snapshotUnderMouse(capturable)

        let frozen: [ScreenFreezer.FrozenScreen]
        do {
            frozen = try await ScreenFreezer.freezeAll()
        } catch {
            logger.error("Falha ao congelar a tela: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.freezeFailed(error.localizedDescription)
        }
        guard !frozen.isEmpty else { throw CaptureError.freezeFailed("nenhum monitor") }
        let snapshot = await early
        logger.notice("Tela congelada: \(frozen.count, privacy: .public) monitor(es).")

        // O F chegou enquanto congelava: a foto já é a tela inteira, nem abre o editor.
        if pendingFullScreen, let shot = Self.screenUnderMouse(in: frozen) {
            return .thumbnail(shot.image, scale: shot.screen.backingScaleFactor)
        }

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
            let image = try await WindowCaptureComposer.compose(window, on: screen, snapshot: snapshot)
            logger.notice("Janela capturada (\(window.ownerName, privacy: .public)): \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
            return .thumbnail(image, scale: screen.backingScaleFactor)
        case .text(let image, let scale):
            logger.notice("Recorte para texto: \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
            return .text(image, scale: scale)
        case .fullScreen(let image, let scale):
            logger.notice("Tela inteira: \(image.width, privacy: .public)×\(image.height, privacy: .public) px.")
            return .thumbnail(image, scale: scale)
        case .cancelled:
            logger.notice("Captura cancelada.")
            return .cancelled
        }
    }

    /// A janela da frente no ponto do mouse, fotografada como está agora.
    private static func snapshotUnderMouse(_ windows: [CapturableWindow]) async -> WindowCaptureComposer.Snapshot? {
        let mouse = NSEvent.mouseLocation
        guard
            let primary = NSScreen.screens.first,
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        else { return nil }
        // `CGWindowList` usa origem no canto superior esquerdo do monitor principal.
        let point = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        guard let target = windows.first(where: { $0.frame.contains(point) }) else { return nil }
        return await WindowCaptureComposer.snapshot(of: target, scale: screen.backingScaleFactor)
    }
}
