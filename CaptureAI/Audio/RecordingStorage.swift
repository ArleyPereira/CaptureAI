import Foundation

/// Diretório persistente das gravações de debug/temporárias.
enum RecordingStorage {
    /// Pasta onde os arquivos de áudio ficam salvos para inspeção.
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base
            .appendingPathComponent("CaptureAI", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func newRecordingURL(fileExtension: String = "m4a") -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return directoryURL.appendingPathComponent("captureai-\(stamp).\(fileExtension)")
    }
}
