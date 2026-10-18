import Foundation

/// Estados do fluxo de ditado por voz.
enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    case transcribing
    case inserting
    case success
    case error
    /// Inserção automática falhou — HUD com texto para arrastar/copiar.
    case awaitingManualInsert
}

extension RecordingState {
    /// Rótulo amigável exibido na interface.
    var statusLabel: String {
        switch self {
        case .idle:
            return "Pronto"
        case .recording:
            return "Ouvindo"
        case .paused:
            return "Pausado"
        case .transcribing:
            return "Transcrevendo…"
        case .inserting:
            return "Inserindo…"
        case .success:
            return "Concluído"
        case .error:
            return "Algo deu errado"
        case .awaitingManualInsert:
            return "Texto pronto"
        }
    }
}
