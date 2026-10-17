import Foundation
import Observation

/// Gira o gradiente da borda do HUD em velocidade constante.
///
/// A intensidade da voz ainda alimenta o brilho visual, mas **não** acelera
/// o giro — o movimento fica sempre no mesmo ritmo, falando ou em silêncio.
@Observable
@MainActor
final class OverlayGlowDriver {
    /// Ângulo atual do gradiente, em graus.
    private(set) var phase: Double = 0

    /// Nível de voz suavizado (0...1) usado só para intensidade visual.
    private(set) var intensity: Double = 0

    private var timer: Timer?
    private var lastTick: Date?

    /// Graus por segundo — ritmo fixo, independente da fala.
    private let rotationSpeed: Double = 40

    func start() {
        guard timer == nil else { return }
        lastTick = Date()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
        intensity = 0
    }

    private func tick() {
        let now = Date()
        let delta = min(0.1, now.timeIntervalSince(lastTick ?? now))
        lastTick = now

        let level = Double(LiveAudioMeter.shared.level)
        // Suaviza o brilho: sobe rápido na fala, desce devagar para não piscar.
        let coefficient = level > intensity ? 0.35 : 0.12
        intensity += (level - intensity) * coefficient

        phase = (phase + rotationSpeed * delta).truncatingRemainder(dividingBy: 360)
    }
}
