import Foundation
import FluidAudio
import Observation
import OSLog

/// Download, estado em disco e exclusão do CTC 110M usado na substituição de palavras.
///
/// É um modelo **auxiliar**, separado do Parakeet TDT: o 0.6B não tem head CTC,
/// e é o CTC que confere no áudio se a palavra falada corresponde ao termo
/// cadastrado. Sem ele o ditado funciona igual — só não corrige vocabulário.
///
/// Por isso o download é opcional e fica num card próprio: quem não usa
/// substituições não paga os ~60–70 MB de RAM nem o espaço em disco.
@Observable
@MainActor
final class LocalCtcModelStore {
    static let shared = LocalCtcModelStore()

    /// Tamanho aproximado, para o rótulo antes de conhecer o repo.
    static let estimatedByteCount: Int64 = 98_000_000

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "ctc-store")
    private let variant: CtcModelVariant = .ctc110m

    private(set) var isDownloading = false
    private(set) var downloadProgress: ParakeetDownloadProgress?
    private(set) var onDiskByteCount: Int64 = 0
    private(set) var lastErrorMessage: String?
    private var downloadTask: Task<Void, Never>?
    private var speedSample: (bytes: Int64, at: Date)?

    private init() {
        refreshDiskState()
    }

    var cacheDirectory: URL {
        CtcModels.defaultCacheDirectory(for: variant)
    }

    var isDownloaded: Bool {
        // O `modelsExist` do FluidAudio só confere os dois `.mlmodelc` e o
        // `vocab.json` — o `tokenizer.json` passa despercebido e a falta dele
        // só aparece na primeira ditagem, como boosting que não acontece.
        // Conferimos aqui o que de fato usamos, para uma pasta incompleta voltar
        // a oferecer o download em vez de se dizer pronta.
        CtcModels.modelsExist(at: cacheDirectory)
            && FileManager.default.fileExists(
                atPath: cacheDirectory.appendingPathComponent("tokenizer.json").path
            )
    }

    func refreshDiskState() {
        onDiskByteCount = directoryByteCount(at: cacheDirectory)
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func reportError(_ message: String) {
        lastErrorMessage = message
    }

    /// Baixa o pacote CTC com o mesmo downloader paralelo do Parakeet.
    ///
    /// O downloader do FluidAudio não expõe progresso e busca um arquivo por
    /// vez; usando o nosso, o card do CTC mostra os mesmos indicadores do card
    /// principal — porcentagem, velocidade e tamanho.
    func download() {
        guard !isDownloading else { return }
        lastErrorMessage = nil
        isDownloading = true
        speedSample = nil
        downloadProgress = ParakeetDownloadProgress(
            fractionCompleted: 0,
            bytesReceived: 0,
            totalBytes: Self.estimatedByteCount,
            bytesPerSecond: 0
        )

        let targetDir = cacheDirectory

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await ParakeetFastDownloader.download(.ctc110m, to: targetDir) { received, total in
                    Task { @MainActor in
                        self.applyDownloadProgress(received: received, total: total)
                    }
                }
                try Task.checkCancellation()

                await MainActor.run {
                    self.finishDownload()
                    self.refreshDiskState()
                    self.logger.notice("CTC 110M baixado (compile ocorre no 1º uso).")
                }
            } catch is CancellationError {
                await MainActor.run { self.finishDownload() }
            } catch {
                await MainActor.run {
                    self.finishDownload()
                    self.lastErrorMessage = error.localizedDescription
                    self.logger.error("Download do CTC falhou: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        finishDownload()
    }

    private func finishDownload() {
        isDownloading = false
        downloadProgress = nil
        speedSample = nil
    }

    /// Bytes vêm direto do downloader — os `.partial` são pré-alocados, então
    /// medir o tamanho em disco daria 100% logo no começo.
    private func applyDownloadProgress(received: Int64, total: Int64) {
        let total = max(total, 1)
        let fraction = min(1, max(0, Double(received) / Double(total)))

        let now = Date()
        var speed = downloadProgress?.bytesPerSecond ?? 0
        if let sample = speedSample {
            let elapsed = now.timeIntervalSince(sample.at)
            if elapsed >= 0.4 {
                speed = max(0, Double(received - sample.bytes) / elapsed)
                speedSample = (received, now)
            }
        } else {
            speedSample = (received, now)
        }

        downloadProgress = ParakeetDownloadProgress(
            fractionCompleted: fraction,
            bytesReceived: received,
            totalBytes: total,
            bytesPerSecond: speed
        )
    }

    func delete() throws {
        cancelDownload()
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDirectory.path) {
            try fm.removeItem(at: cacheDirectory)
        }
        refreshDiskState()
        logger.notice("CTC removido do disco.")
    }

    private func directoryByteCount(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard !["partial", "etag"].contains(fileURL.pathExtension) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
