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
                // transferência (e para a pasta), e a miniatura fica para
                // copiar de novo ou descartar.
                copy(image, scale: scale)
                showThumbnail(image, scale: scale)
            }
        } catch {
            logger.error("Captura falhou: \(error.localizedDescription, privacy: .public)")
            lastMessage = error.localizedDescription
        }
    }

    /// Vai para a área de transferência com o tamanho em pontos — e para a
    /// pasta de capturas, como toda captura.
    ///
    /// Copiar e salvar não são destinos excludentes: copiar é salvar e, além
    /// disso, deixar a imagem pronta para colar. Sem o tamanho em pontos, a
    /// imagem colada sairia com o dobro do tamanho em telas Retina.
    private func copy(_ image: CGImage, scale: CGFloat, save shouldSave: Bool = true) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
        if shouldSave { save(image) }
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

    /// Mostra a miniatura flutuante.
    ///
    /// A captura já está na pasta e na área de transferência quando ela
    /// aparece. Copy volta a pôr a imagem na área de transferência — útil se
    /// outra coisa foi copiada nesse meio-tempo — sem gravar um segundo
    /// arquivo; Save confirma o que já está gravado.
    private func showThumbnail(_ image: CGImage, scale: CGFloat) {
        thumbnail.show(
            image: image,
            scale: scale,
            onCopy: { [weak self] in self?.copy(image, scale: scale, save: false) },
            onSave: { true }
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
