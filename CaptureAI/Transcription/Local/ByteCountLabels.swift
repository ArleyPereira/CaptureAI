import Foundation

extension Int64 {
    /// Tamanho em disco no estilo do Finder (KB/MB/GB).
    var voiceIAByteCountLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        // Sem isto o zero vira "Zero KB", que aparece no início de todo download.
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: self)
    }

    /// Velocidade de download — unidade adaptativa, para o rótulo não pular
    /// de escala a cada amostra.
    var voiceIAThroughputLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: self)
    }
}
