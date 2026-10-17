import Foundation

/// Material disponível assim que a captura para, antes de o `.m4a` existir.
struct StoppedCapture {
    /// PCM 16 kHz mono da ditagem inteira.
    let pcmSamples: [Float]
    /// Energia acumulada durante a captura (decide "houve fala?" sem revarrer).
    let speechStats: SpeechEnergyStats
    /// Onde o `.m4a` vai aparecer quando a finalização terminar.
    let fileURL: URL

    /// Duração real capturada, derivada do próprio PCM.
    var durationSeconds: Double {
        Double(pcmSamples.count) / 16_000
    }
}

/// Contrato para captura de áudio do microfone.
protocol AudioRecorderProtocol: AnyObject {
    /// Indica se há sessão de gravação aberta (ativa ou pausada).
    var isRecording: Bool { get }

    /// Indica se a captura está pausada (sessão ainda aberta).
    var isPaused: Bool { get }

    /// Nível de áudio normalizado (0...1).
    var audioLevel: Float { get }

    /// Métricas da última captura concluída.
    var lastDiagnostics: CaptureDiagnostics { get }

    /// Inicia a gravação em um arquivo temporário.
    func startRecording() async throws

    /// Pausa a captura sem fechar o arquivo.
    func pauseRecording() async throws

    /// Retoma a captura no mesmo arquivo.
    func resumeRecording() async throws

    /// Encerra a gravação e devolve o URL do arquivo gerado.
    ///
    /// Aguarda a finalização do `.m4a`. No ditado prefira `stopCapture()`:
    /// a ASR local só precisa do PCM e o encoder AAC não deve segurar a fila.
    func stopRecording() async throws -> URL

    /// Encerra a captura e devolve o PCM na hora, sem esperar o `.m4a`.
    func stopCapture() async throws -> StoppedCapture

    /// Aguarda a finalização do `.m4a` iniciada por `stopCapture()`.
    func finalizedRecording() async throws -> URL

    /// Remove um arquivo de gravação temporário.
    func deleteRecording(at url: URL) throws
}
