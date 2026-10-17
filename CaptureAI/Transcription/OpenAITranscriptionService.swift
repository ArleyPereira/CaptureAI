import Foundation
import OSLog

/// Transcrição via OpenAI Audio API — **sem retry automático**.
///
/// Em modo teste (`isTestModeEnabled`) devolve texto mock e não faz rede,
/// para não gastar créditos durante validação do fluxo.
final class OpenAITranscriptionService: TranscriptionService, @unchecked Sendable {
    private let settings: AppSettings
    private let session: URLSession
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "transcription")

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func transcribe(audioURL: URL, pcmSamples: [Float]? = nil) async throws -> String {
        // OpenAI sempre envia o arquivo; PCM em memória não se aplica aqui.
        let testMode = await MainActor.run { settings.isTestModeEnabled }
        if testMode {
            logger.info("Modo teste ativo — transcrição mock, sem chamada à OpenAI.")
            try? await Task.sleep(for: .milliseconds(350))
            return TranscriptionConfiguration.mockTranscriptionText
        }

        let apiKey: String = try await MainActor.run {
            settings.refreshAPIKeyStatus()
            guard settings.hasAPIKey, let key = try settings.openAIAPIKey(), !key.isEmpty else {
                throw VoiceInputError.missingAPIKey
            }
            return key
        }

        try validateFileForUpload(audioURL)

        let language = await MainActor.run { settings.transcriptionLanguage }
        let request = try makeRequest(audioURL: audioURL, apiKey: apiKey, language: language)

        logger.info("Enviando áudio para OpenAI (modelo \(TranscriptionConfiguration.model, privacy: .public)).")

        let data: Data
        let response: URLResponse
        do {
            // Uma única tentativa — sem retry automático.
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Falha de rede na transcrição (sem retry).")
            throw VoiceInputError.transcriptionFailed
        }

        guard let http = response as? HTTPURLResponse else {
            throw VoiceInputError.transcriptionFailed
        }

        guard (200...299).contains(http.statusCode) else {
            logger.error("OpenAI HTTP \(http.statusCode) — corpo omitido.")
            throw VoiceInputError.transcriptionFailed
        }

        let text = try parseTranscriptionText(from: data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceInputError.emptyTranscription
        }
        return trimmed
    }

    // MARK: - Privado

    private func validateFileForUpload(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 512 else {
            throw VoiceInputError.emptyRecording
        }
        guard size <= TranscriptionConfiguration.maximumUploadBytes else {
            throw VoiceInputError.recordingTooLong
        }
    }

    private func makeRequest(audioURL: URL, apiKey: String, language: String) throws -> URLRequest {
        let boundary = "CaptureAI-\(UUID().uuidString)"
        var request = URLRequest(url: TranscriptionConfiguration.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let fileData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: TranscriptionConfiguration.model)
        if language != "auto" {
            appendField(name: "language", value: language)
        }
        appendField(name: "response_format", value: "json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        return request
    }

    private func parseTranscriptionText(from data: Data) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        throw VoiceInputError.transcriptionFailed
    }
}
