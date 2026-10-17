import Foundation

/// Contrato para serviços de transcrição de áudio.
protocol TranscriptionService {
    /// Transcreve o áudio. Quando `pcmSamples` vem preenchido (captura local em
    /// 16 kHz mono), a ASR local usa essas amostras e não decodifica o arquivo.
    func transcribe(audioURL: URL, pcmSamples: [Float]?) async throws -> String

    /// Igual à anterior, mas permite pedir o texto **cru**.
    ///
    /// Existe para o microfone do campo "Original" na substituição de palavras:
    /// lá o que interessa é justamente a grafia errada que o modelo produz. Com
    /// a substituição ligada, ela seria corrigida antes de chegar ao campo e
    /// nunca daria para cadastrar o par.
    func transcribe(
        audioURL: URL,
        pcmSamples: [Float]?,
        applyWordReplacements: Bool
    ) async throws -> String
}

extension TranscriptionService {
    func transcribe(audioURL: URL) async throws -> String {
        try await transcribe(audioURL: audioURL, pcmSamples: nil)
    }

    /// Backends sem vocabulário (OpenAI, modo teste) ignoram o pedido: não há
    /// substituição para desligar.
    func transcribe(
        audioURL: URL,
        pcmSamples: [Float]?,
        applyWordReplacements: Bool
    ) async throws -> String {
        try await transcribe(audioURL: audioURL, pcmSamples: pcmSamples)
    }
}
