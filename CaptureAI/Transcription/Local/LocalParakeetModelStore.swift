import Foundation
import FluidAudio
import Observation
import OSLog

/// Progresso do download do Parakeet (percentual, velocidade e tamanho).
struct ParakeetDownloadProgress: Sendable, Equatable {
    var fractionCompleted: Double
    var bytesReceived: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double

    var percentLabel: String {
        "\(Int((fractionCompleted * 100).rounded()))%"
    }

    var speedLabel: String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(Int64(bytesPerSecond).captureAIThroughputLabel)/s"
    }

    var sizeLabel: String {
        let received = bytesReceived.captureAIByteCountLabel
        if totalBytes > 0 {
            return "\(received) / \(totalBytes.captureAIByteCountLabel)"
        }
        return received
    }
}

/// Download, estado em disco e exclusão do Parakeet TDT 0.6B V3 (FluidAudio / Core ML).
///
/// O download usa `ParakeetFastDownloader` (faixas paralelas) em vez do
/// downloader do FluidAudio, que baixa um arquivo por vez numa conexão só e
/// rende ~1,4 MB/s contra ~33 MB/s em paralelo. A compilação Core ML fica para
/// o primeiro ditado.
@Observable
@MainActor
final class LocalParakeetModelStore {
    static let shared = LocalParakeetModelStore()

    /// Tamanho aproximado do pacote Core ML (rótulo da UI antes de listar o repo).
    static let estimatedByteCount: Int64 = 496_000_000

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "parakeet-store")
    private let version: AsrModelVersion = .v3
    private let encoderPrecision: ParakeetEncoderPrecision = .int8

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
        AsrModels.defaultCacheDirectory(for: version)
    }

    var isDownloaded: Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: version, encoderPrecision: encoderPrecision)
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

    /// Baixa apenas os arquivos do Hugging Face (sem compile Core ML).
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
                try await ParakeetFastDownloader.download(.parakeet, to: targetDir) { received, total in
                    Task { @MainActor in
                        self.applyDownloadProgress(received: received, total: total)
                    }
                }
                try Task.checkCancellation()

                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = nil
                    self.speedSample = nil
                    self.refreshDiskState()
                    self.logger.notice("Parakeet TDT 0.6B V3 baixado (compile ocorre no 1º uso).")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = nil
                    self.speedSample = nil
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = nil
                    self.speedSample = nil
                    self.lastErrorMessage = error.localizedDescription
                    self.logger.error("Download Parakeet falhou: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = nil
        speedSample = nil
    }

    func delete() throws {
        cancelDownload()
        let fm = FileManager.default
        let dir = cacheDirectory
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        refreshDiskState()
        logger.notice("Parakeet removido do disco.")
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

    /// Bytes do modelo instalado — ignora `.partial` e o sidecar `.etag`.
    ///
    /// Os `.partial` são pré-alocados no tamanho final do arquivo, então
    /// contá-los faria o rótulo mostrar o pacote inteiro logo no começo do
    /// download. E um órfão de force quit deixaria o número inflado para sempre,
    /// sugerindo um modelo em disco que não dá para usar.
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
