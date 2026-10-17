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
                // No modo janela não há barra: a imagem vai para a área de
                // transferência e a miniatura oferece salvar ou descartar.
                let recorded = copy(image, scale: scale)
                showThumbnail(image, scale: scale, recorded: recorded)
            }
        } catch {
            logger.error("Captura falhou: \(error.localizedDescription, privacy: .public)")
            lastMessage = error.localizedDescription
        }
    }

    /// Vai para a área de transferência com o tamanho em pontos, e entra no
    /// histórico de imagens.
    ///
    /// Sem o tamanho, a imagem colada num documento sairia com o dobro do
    /// tamanho em telas Retina. Sem o registro, a captura sumiria da aba
    /// Imagens assim que outra coisa fosse copiada.
    @discardableResult
    private func copy(_ image: CGImage, scale: CGFloat, record: Bool = true) -> URL? {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: size)])

        guard record, let data = Self.png(image) else { return nil }
        return store.recordCopied(png: data)
    }

    /// Grava na pasta do usuário. Se a captura já estava no histórico de
    /// cópias, o arquivo é movido para lá em vez de duplicado.
    @discardableResult
    private func save(_ image: CGImage, replacingCopied copied: URL? = nil) -> Bool {
        guard let data = Self.png(image) else { return false }
        do {
            try store.save(png: data, replacingCopied: copied)
            return true
        } catch {
            logger.error("Falha ao salvar captura: \(error.localizedDescription, privacy: .public)")
            lastMessage = "Não foi possível salvar a captura."
            return false
        }
    }

    /// Mostra a miniatura flutuante, de onde dá para copiar, salvar ou descartar.
    private func showThumbnail(_ image: CGImage, scale: CGFloat, recorded: URL?) {
        thumbnail.show(
            image: image,
            scale: scale,
            // A captura já foi registrada ao entrar na área de transferência;
            // copiar de novo daqui não cria um segundo item.
            onCopy: { [weak self] in self?.copy(image, scale: scale, record: false) },
            onSave: { [weak self] in self?.save(image, replacingCopied: recorded) ?? false }
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
