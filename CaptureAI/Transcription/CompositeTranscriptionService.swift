import Foundation

/// Escolhe entre a API da OpenAI e o Parakeet local conforme as preferências.
final class CompositeTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let settings: AppSettings
    private let openAI: OpenAITranscriptionService
    private let localParakeet: LocalParakeetTranscriptionService

    init(settings: AppSettings) {
        self.settings = settings
        self.openAI = OpenAITranscriptionService(settings: settings)
        self.localParakeet = LocalParakeetTranscriptionService(settings: settings)
    }

    func transcribe(audioURL: URL, pcmSamples: [Float]? = nil) async throws -> String {
        try await transcribe(audioURL: audioURL, pcmSamples: pcmSamples, applyWordReplacements: true)
    }

    func transcribe(
        audioURL: URL,
        pcmSamples: [Float]?,
        applyWordReplacements: Bool
    ) async throws -> String {
        // Um hop só: cada `MainActor.run` é uma ida e volta de scheduler no
        // caminho crítico da ditagem.
        let (testMode, backend) = await MainActor.run {
            (settings.isTestModeEnabled, settings.transcriptionBackend)
        }

        // O modo teste mantém o mock dentro do serviço OpenAI (sem rede).
        guard !testMode, backend == "local" else {
            return try await openAI.transcribe(audioURL: audioURL, pcmSamples: nil)
        }
        return try await localParakeet.transcribe(
            audioURL: audioURL,
            pcmSamples: pcmSamples,
            applyWordReplacements: applyWordReplacements
        )
    }

    /// Pré-carrega o Parakeet quando ele é o backend ativo.
    func warmLocalModelsIfNeeded() {
        Task { @MainActor in
            guard settings.transcriptionBackend == "local",
                  !settings.isTestModeEnabled else { return }
            localParakeet.warmUpIfNeeded()
        }
    }

    /// Descarta o Parakeet em cache (modo teste, volta para a API, exclusão do modelo).
    func unloadCachedLocalModel() {
        localParakeet.unloadCachedModel()
    }
}
