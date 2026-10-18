import AVFoundation
import Foundation
import Observation
import OSLog

/// Reproduz o `.m4a` de uma entrada do histórico na barra flutuante.
///
/// Vive separado do `AudioRecorder` de propósito: gravar e tocar nunca
/// acontecem ao mesmo tempo, e misturar os dois deixaria o estado da barra
/// ambíguo — a mesma barra teria dois donos.
@Observable
@MainActor
final class AudioPlaybackController: NSObject {
    /// O que a barra precisa saber para se desenhar.
    struct Session: Equatable {
        let entryID: UUID
        var isPaused: Bool
        var elapsed: TimeInterval
        var duration: TimeInterval

        /// `mm:ss` decorrido, no mesmo formato do histórico.
        var elapsedLabel: String {
            let total = max(0, Int(elapsed))
            return String(format: "%02d:%02d", total / 60, total % 60)
        }

        var fraction: Double {
            guard duration > 0 else { return 0 }
            return min(1, max(0, elapsed / duration))
        }
    }

    /// Por que a reprodução não começou.
    enum StartError: LocalizedError {
        case fileMissing
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                return "O arquivo de áudio desta ditagem não está mais no disco."
            case .unreadable(let reason):
                return "Não foi possível reproduzir o áudio: \(reason)"
            }
        }
    }

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "playback")

    /// `nil` = nada tocando. A barra observa isto.
    private(set) var session: Session?

    /// Chamado quando a sessão começa, muda ou termina — o `AppState` usa para
    /// atualizar a barra flutuante.
    var onSessionChanged: (() -> Void)?

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    private var meterTicker: Task<Void, Never>?

    /// Começa a tocar. Trocar de entrada com outra em curso substitui a sessão.
    func play(entryID: UUID, url: URL) throws {
        stop()

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StartError.fileMissing
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw StartError.unreadable(error.localizedDescription)
        }

        player.delegate = self
        // A onda da barra lê o `LiveAudioMeter`; sem metering ela ficaria parada
        // no piso, dando a impressão de que a reprodução travou.
        player.isMeteringEnabled = true
        guard player.prepareToPlay(), player.play() else {
            throw StartError.unreadable("o sistema recusou iniciar a reprodução")
        }

        self.player = player
        session = Session(
            entryID: entryID,
            isPaused: false,
            elapsed: 0,
            duration: player.duration
        )
        LiveAudioMeter.shared.reset()
        onSessionChanged?()
        startTicker()
        startMeterTicker()
        logger.notice("Reproduzindo áudio do histórico (\(String(format: "%.1f", player.duration)) s).")
    }

    func togglePause() {
        guard let player, session != nil else { return }
        if player.isPlaying {
            player.pause()
            session?.isPaused = true
            // Congela a onda junto com o áudio.
            LiveAudioMeter.shared.setLevel(0)
        } else {
            player.play()
            session?.isPaused = false
        }
        onSessionChanged?()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        meterTicker?.cancel()
        meterTicker = nil
        LiveAudioMeter.shared.reset()
        player?.stop()
        player = nil
        guard session != nil else { return }
        session = nil
        onSessionChanged?()
    }

    /// Atualiza o tempo decorrido enquanto toca.
    ///
    /// 0,2 s é o passo: o rótulo é `mm:ss`, então amostrar mais rápido só
    /// gastaria ciclos, e mais devagar faria o segundo virar com atraso visível.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player, self.session != nil else { return }
                guard !Task.isCancelled else { return }
                self.session?.elapsed = player.currentTime
                self.onSessionChanged?()
            }
        }
    }

    /// Alimenta a onda com o volume do que está tocando.
    ///
    /// Fica separado do ticker do rótulo porque roda seis vezes mais rápido: a
    /// onda precisa disso para parecer viva, mas notificar a barra nessa
    /// frequência a faria refazer o layout 30 vezes por segundo à toa. Aqui só
    /// o medidor é atualizado — o desenho já acompanha por conta própria.
    private func startMeterTicker() {
        meterTicker?.cancel()
        meterTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, let player = self.player, self.session != nil else { return }
                guard !Task.isCancelled, player.isPlaying else { continue }

                player.updateMeters()
                LiveAudioMeter.shared.setLevel(Self.normalizedLevel(player.averagePower(forChannel: 0)))
            }
        }
    }

    /// dBFS (-160...0) para 0...1, com a mesma curva do medidor de captura.
    ///
    /// O corte em -50 dB descarta o ruído de fundo da gravação; sem ele a onda
    /// nunca desceria nas pausas da fala.
    private static func normalizedLevel(_ decibels: Float) -> Float {
        let floor: Float = -50
        guard decibels > floor else { return 0 }
        let normalized = (decibels - floor) / -floor
        return min(1, pow(max(0, normalized), 0.6))
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.logger.error(
                "Erro decodificando áudio do histórico: \(error?.localizedDescription ?? "desconhecido", privacy: .public)"
            )
            self?.stop()
        }
    }
}
