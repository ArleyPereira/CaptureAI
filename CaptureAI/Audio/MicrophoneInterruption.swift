import Foundation

/// Motivo de a captura ter sido pausada sozinha, sem o usuário pedir.
///
/// Quando o microfone some ou é mutado no meio da ditagem, gravar seguiria
/// produzindo silêncio e a transcrição sairia vazia (ou pela metade). O
/// gravador pausa e devolve o motivo, para o usuário decidir: religar o
/// microfone e continuar, encerrar com o que já foi dito ou descartar.
enum MicrophoneInterruption: Equatable, Sendable {
    /// O dispositivo saiu do sistema (fone desconectado, Bluetooth caiu).
    case disconnected(deviceName: String)
    /// O dispositivo foi mutado ou teve o volume de entrada zerado.
    case muted(deviceName: String)
    /// A sessão de captura parou por erro do sistema.
    case stopped(deviceName: String)

    var deviceName: String {
        switch self {
        case .disconnected(let name), .muted(let name), .stopped(let name):
            return name
        }
    }

    /// Texto curto, cabe na barra flutuante ao lado da duração.
    var title: String {
        switch self {
        case .disconnected:
            return "Microfone desconectado"
        case .muted:
            return "Microfone mutado"
        case .stopped:
            return "Microfone parou"
        }
    }

    /// Explicação completa, para o tooltip e o menu.
    var message: String {
        switch self {
        case .disconnected(let name):
            return "\(name) foi desconectado. A gravação está pausada: reconecte e toque em ▶, ou toque em ▶ para seguir com o padrão do macOS. Também dá para encerrar com o que já foi dito."
        case .muted(let name):
            return "\(name) está mutado. A gravação está pausada: tire o mudo e continue, ou encerre com o que já foi dito."
        case .stopped(let name):
            return "\(name) parou de enviar áudio. A gravação está pausada: continue para tentar de novo, ou encerre com o que já foi dito."
        }
    }
}
