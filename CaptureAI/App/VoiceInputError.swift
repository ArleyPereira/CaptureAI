import Foundation

/// Erros tipados do CaptureAI com mensagens amigáveis.
enum VoiceInputError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case noInputDevice
    case recordingFailed
    case recordingNotInProgress
    case emptyRecording
    case transcriptionFailed
    case emptyTranscription
    case missingAPIKey
    case recordingTooLong
    case textInsertionFailed
    case accessibilityPermissionDenied
    case noFocusedElement
    case busy
    case localModelMissing
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "É necessário permitir o acesso ao microfone."
        case .noInputDevice:
            return "Nenhum microfone foi encontrado no sistema."
        case .recordingFailed:
            return "Não foi possível capturar o microfone. Tente novamente."
        case .recordingNotInProgress:
            return "Nenhuma gravação está em andamento."
        case .emptyRecording:
            return "A gravação veio sem áudio. Confira o microfone padrão do macOS e tente de novo."
        case .transcriptionFailed:
            return "Não foi possível transcrever o áudio. Tente novamente (sem nova tentativa automática)."
        case .emptyTranscription:
            return "A transcrição veio vazia. Tente falar novamente."
        case .missingAPIKey:
            return "Configure a API key da OpenAI em Configurações, ou ative o modo teste."
        case .recordingTooLong:
            return "A gravação ficou grande demais para enviar. Encerre um pouco antes e tente de novo."
        case .textInsertionFailed:
            return "Não foi possível inserir o texto no aplicativo em foco."
        case .accessibilityPermissionDenied:
            return "É necessário permitir o acesso de Acessibilidade."
        case .noFocusedElement:
            return "Nenhum campo de texto está em foco. O texto foi copiado para a área de transferência — cole com ⌘V."
        case .busy:
            return "Aguarde a transcrição/inserção atual terminar."
        case .localModelMissing:
            return "Baixe o modelo local em Configurações → Modelos → Local antes de usar a transcrição local."
        case .noSpeechDetected:
            return "Nenhuma fala detectada. Tente ditado de novo."
        }
    }
}
