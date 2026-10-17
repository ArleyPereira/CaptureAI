import Foundation

/// Energia acumulada durante a captura, para decidir "houve fala?" sem
/// varrer o PCM inteiro de novo no fim da ditagem.
///
/// `AudioRecorder.measure` já percorre cada bloco para calcular o nível da
/// waveform; alimentar estes campos ali sai de graça e tira um loop O(n) do
/// caminho crítico (era ~160 mil amostras para 10 s de fala).
struct SpeechEnergyStats {
    var sampleCount: Int = 0
    var sumSquares: Double = 0
    var peak: Float = 0
    var loudSampleCount: Int = 0

    var isEmpty: Bool { sampleCount == 0 }
}

/// Decide se a captura tem energia de fala suficiente para valer transcrição.
enum SpeechPresenceAnalyzer {
    /// RMS abaixo disso + pico baixo → gravação praticamente muda.
    private static let silenceRMSThreshold: Double = 0.010
    private static let silencePeakThreshold: Float = 0.050

    /// Fração mínima de amostras “audíveis” para considerar que houve fala.
    private static let minimumLoudFrameRatio: Double = 0.012
    static let loudSampleThreshold: Float = 0.022


    /// `true` se o PCM 16 kHz mono tem energia suficiente de fala.
    ///
    /// Prefira `hasSpeechEnergy(stats:)` quando as estatísticas já vierem da
    /// captura: esta versão precisa varrer todas as amostras.
    static func hasSpeechEnergy(in samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }

        var stats = SpeechEnergyStats()
        for sample in samples {
            let absolute = abs(sample)
            if absolute > stats.peak {
                stats.peak = absolute
            }
            stats.sumSquares += Double(sample) * Double(sample)
            if absolute >= loudSampleThreshold {
                stats.loudSampleCount += 1
            }
        }
        stats.sampleCount = samples.count

        return hasSpeechEnergy(stats: stats)
    }

    /// Mesma decisão, a partir da energia acumulada durante a captura.
    static func hasSpeechEnergy(stats: SpeechEnergyStats) -> Bool {
        guard !stats.isEmpty else { return false }

        let rms = sqrt(stats.sumSquares / Double(stats.sampleCount))
        let loudRatio = Double(stats.loudSampleCount) / Double(stats.sampleCount)

        if rms < silenceRMSThreshold && stats.peak < silencePeakThreshold {
            return false
        }
        if loudRatio < minimumLoudFrameRatio && rms < silenceRMSThreshold * 1.6 {
            return false
        }
        return true
    }
}
