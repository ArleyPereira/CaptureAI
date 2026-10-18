import Foundation

/// Configuração centralizada da transcrição OpenAI (modelo único no código).
enum TranscriptionConfiguration {
    /// Modelo barato para ditado curto (~US$ 0,003/min).
    static let model = "gpt-4o-mini-transcribe"

    /// Endpoint oficial de transcrição de áudio.
    static let transcriptionURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// Tamanho máximo do arquivo antes do upload (bytes).
    static let maximumUploadBytes = 2 * 1_024 * 1_024

    /// Texto devolvido no modo teste (sem HTTP).
    static let mockTranscriptionText = "Transcrição de teste (modo sem OpenAI)."
}
