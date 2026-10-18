import Foundation
import OSLog

/// Cronômetro de uma ditagem: acumula marcos e emite **uma linha só** no fim.
///
/// Serve para responder "onde foram os milissegundos" sem espalhar `logger` por
/// todo o pipeline. Cada `mark` guarda o delta desde o marco anterior, então a
/// linha final lê como um extrato: `captura 12 ms, asr 240 ms, inserção 30 ms`.
///
/// Usa `DispatchTime` (monotônico) em vez de `Date`: ajuste de relógio no meio
/// da ditagem não vira medição negativa.
struct LatencyTrace {
    private static let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "latency")

    private let label: String
    private let start: DispatchTime
    private var last: DispatchTime
    private var marks: [(name: String, deltaMs: Double)] = []

    init(_ label: String) {
        self.label = label
        let now = DispatchTime.now()
        self.start = now
        self.last = now
    }

    mutating func mark(_ name: String) {
        let now = DispatchTime.now()
        marks.append((name, Self.milliseconds(from: last, to: now)))
        last = now
    }

    func summary() {
        let total = Self.milliseconds(from: start, to: DispatchTime.now())
        let detail = marks
            .map { "\($0.name) \(Self.format($0.deltaMs))" }
            .joined(separator: ", ")
        Self.logger.notice(
            "\(label, privacy: .public): total \(Self.format(total), privacy: .public) — \(detail, privacy: .public)"
        )
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.0f ms", milliseconds)
    }

    private static func milliseconds(from: DispatchTime, to: DispatchTime) -> Double {
        Double(to.uptimeNanoseconds &- from.uptimeNanoseconds) / 1_000_000
    }
}
