import Foundation

/// Métricas da última captura de microfone.
///
/// Servem para distinguir três falhas que geram o mesmo sintoma na interface
/// (waveform parada): nenhum buffer entregue pelo sistema, buffers entregues
/// porém silenciosos, ou arquivo escrito sem conteúdo.
struct CaptureDiagnostics: Sendable, Equatable {
    var deviceName: String
    var sampleRate: Double
    var bufferCount: Int
    var peakAmplitude: Float
    var durationSeconds: Double
    var byteCount: Int
    /// Arquivo gerado, preservado mesmo quando a captura é considerada inválida.
    var fileURL: URL?

    static let empty = CaptureDiagnostics(
        deviceName: "—",
        sampleRate: 0,
        bufferCount: 0,
        peakAmplitude: 0,
        durationSeconds: 0,
        byteCount: 0,
        fileURL: nil
    )

    /// Sistema não entregou nenhum bloco de áudio (permissão ou dispositivo).
    var receivedNoAudio: Bool { bufferCount == 0 }

    /// Buffers chegaram, mas sem sinal audível.
    var isSilent: Bool { peakAmplitude < 0.0005 }

    var summary: String {
        String(
            format: "%@ · %.0f kHz · %d blocos · pico %.3f · %.1fs · %.1f KB",
            deviceName,
            sampleRate / 1_000,
            bufferCount,
            peakAmplitude,
            durationSeconds,
            Double(byteCount) / 1_024
        )
    }
}
