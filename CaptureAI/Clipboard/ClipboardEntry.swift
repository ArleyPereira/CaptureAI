import Foundation

/// O que foi copiado: texto corrido ou um endereço.
///
/// A distinção existe para o filtro da lista. Ela é derivada do conteúdo uma
/// única vez, na hora da captura, e gravada junto: reclassificar a cada
/// abertura da tela custaria um `NSDataDetector` por item.
enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text
    case link
}

/// Um item do histórico da área de transferência.
struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// O conteúdo copiado, já sem espaços nas pontas.
    var content: String
    let kind: ClipboardKind
    let createdAt: Date
    /// Quem estava em primeiro plano quando a cópia aconteceu (ex.: `Safari`).
    ///
    /// É só um rótulo de origem para a lista. Guardamos o nome legível e não o
    /// bundle id porque é isso que aparece na tela, e o app de origem pode nem
    /// estar instalado quando o histórico for lido de novo.
    let sourceApp: String?
    /// Marcado pelo usuário para sobreviver ao "limpar tudo" e ao corte por
    /// limite de itens.
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        content: String,
        kind: ClipboardKind,
        createdAt: Date = Date(),
        sourceApp: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.isPinned = isPinned
    }

    /// Primeira linha não vazia, para a lista não exibir um bloco inteiro.
    var previewLine: String {
        content
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? content
    }

    /// Quantas linhas o conteúdo tem — a lista mostra "+N linhas" quando passa de uma.
    var lineCount: Int {
        content.split(whereSeparator: \.isNewline).count
    }

    /// Host do endereço, usado como rótulo curto nos itens do tipo link.
    var linkHost: String? {
        guard kind == .link, let url = URL(string: content) else { return nil }
        return url.host()
    }
}

extension ClipboardEntry {
    /// Decide se o texto copiado é um endereço.
    ///
    /// Exige que o detector cubra a string **inteira**: um parágrafo que menciona
    /// um site de passagem continua sendo texto, senão o filtro "Links" viraria
    /// um segundo "Todos".
    static func classify(_ text: String) -> ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return .text }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return .text
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range) else { return .text }
        return match.range == range ? .link : .text
    }
}

/// Faixas de tempo do filtro da lista.
enum ClipboardPeriod: String, CaseIterable, Identifiable {
    case all
    case today
    case yesterday
    case week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tudo"
        case .today: return "Hoje"
        case .yesterday: return "Ontem"
        case .week: return "Esta semana"
        }
    }

    /// Testa uma data contra a faixa, no fuso e calendário do usuário.
    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .yesterday:
            return calendar.isDateInYesterday(date)
        case .week:
            // "Esta semana" é a semana corrente do calendário, não os últimos
            // sete dias: é assim que a pessoa pensa ao procurar algo de segunda.
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
            return interval.contains(date)
        }
    }
}
