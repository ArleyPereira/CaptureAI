import Foundation

/// Medidor com histórico deslizante para desenhar a waveform estilo “voice message”.
nonisolated final class LiveAudioMeter: @unchecked Sendable {
    static let shared = LiveAudioMeter()

    private let lock = NSLock()
    private var levelValue: Float = 0
    private var history: [Float]
    private let historyCount = 40

    private init() {
        history = Array(repeating: 0.16, count: historyCount)
    }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return levelValue
    }

    var peak: Float { level }

    /// Níveis por barra (esquerda → direita, mais recente à direita).
    func barLevels(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else { return [] }
        if count == history.count {
            return history
        }

        var result = [Float]()
        result.reserveCapacity(count)
        for index in 0..<count {
            let sourceIndex = Int(round(Double(index) / Double(max(count - 1, 1)) * Double(history.count - 1)))
            result.append(history[min(sourceIndex, history.count - 1)])
        }
        return result
    }

    func reset() {
        lock.lock()
        levelValue = 0
        history = Array(repeating: 0.16, count: historyCount)
        lock.unlock()
    }

    /// Define o nível já normalizado (0...1).
    func setLevel(_ value: Float) {
        let shaped = max(0, min(1, value))

        lock.lock()
        let coefficient: Float = shaped > levelValue ? 0.8 : 0.45
        levelValue += (shaped - levelValue) * coefficient
        if levelValue < 0.015 {
            levelValue = 0
        }

        history.removeFirst()
        // Piso visual mínimo para não sumir as barras.
        history.append(max(0.16, levelValue))
        lock.unlock()
    }

    func update(rms: Float, peak: Float) {
        let raw = max(rms * 40, peak * 22)
        setLevel(min(1, pow(max(0, raw), 0.5)))
    }
}
