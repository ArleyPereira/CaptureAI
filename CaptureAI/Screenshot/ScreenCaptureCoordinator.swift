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
    private let thumbnail = CaptureThumbnailController()
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "screen-capture")

    /// Última mensagem para a UI (sucesso ou falha), consumida pela aba.
    var lastMessage: String?

    init(settings: AppSettings, store: ScreenshotStore, service: ScreenCaptureService? = nil) {
        self.store = store
        self.service = service ?? ScreenCaptureService()
    }

    /// Começa uma captura. Chamado pelo atalho global e pelo botão da aba.
    func beginCapture(mode: CaptureMode = .area) {
        Task { await performCapture(mode: mode) }
    }

    private func performCapture(mode: CaptureMode) async {
        do {
            switch try await service.captureInteractively(mode: mode) {
            case .cancelled:
                return
            case .copy(let image, let scale):
                // Na área a decisão já foi tomada na barra; a miniatura seria
                // uma pergunta a mais sobre algo resolvido.
                copy(image, scale: scale)
            case .save(let image, _):
                save(image)
            case .window(let image, let scale):
                // No modo janela não há barra na tela: a decisão fica para a
                // miniatura. Nada vai para a área de transferência nem para a
                // pasta até a pessoa escolher Copy ou Save.
                showThumbnail(image, scale: scale)
            }
        } catch {
            logger.error("Captura falhou: \(error.localizedDescription, privacy: .public)")
            lastMessage = error.localizedDescription
        }
    }

    /// Vai para a área de transferência com o tamanho em pontos.
    ///
    /// Copiar não grava arquivo nem entra no histórico de Imagens — é para
    /// colar agora. Quem quer guardar usa Salvar, nos dois modos de captura.
    /// Sem o tamanho em pontos, a imagem colada sairia com o dobro do tamanho
    /// em telas Retina.
    private func copy(_ image: CGImage, scale: CGFloat) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
    }

    @discardableResult
    private func save(_ image: CGImage) -> Bool {
        guard let data = Self.png(image) else { return false }
        do {
            try store.save(png: data)
            return true
        } catch {
            logger.error("Falha ao salvar captura: \(error.localizedDescription, privacy: .public)")
            lastMessage = "Não foi possível salvar a captura."
            return false
        }
    }

    /// Mostra a miniatura flutuante com as duas saídas da captura de janela.
    ///
    /// Copy só põe a imagem na área de transferência, sem gravar arquivo —
    /// é para colar agora. Save grava na pasta, e é isso que a faz entrar no
    /// histórico de Imagens.
    private func showThumbnail(_ image: CGImage, scale: CGFloat) {
        thumbnail.show(
            image: image,
            scale: scale,
            onCopy: { [weak self] in self?.copy(image, scale: scale) },
            onSave: { [weak self] in self?.save(image) ?? false }
        )
    }

    private static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Acorde Print Screen + W: abre direto no modo janela ou, se o editor
    /// já estiver aberto ou abrindo, troca para ele.
    func requestWindowMode() {
        if service.isBusy {
            service.requestWindowMode()
        } else {
            beginCapture(mode: .window)
        }
    }

}
