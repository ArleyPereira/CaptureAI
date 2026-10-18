import Foundation
import Observation
import OSLog

/// Persiste o histórico da área de transferência em JSON (Application Support).
///
/// Mesmo desenho do `TranscriptionHistoryStore`: lista em memória para a UI,
/// gravação serial fora do MainActor. A diferença é o volume — aqui entra um
/// item a cada cópia, não a cada ditagem —, por isso existe um teto de itens.
@Observable
@MainActor
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    /// Teto de itens não fixados.
    ///
    /// O arquivo é lido e escrito inteiro a cada mudança; sem teto, quem copia
    /// o dia todo acabaria pagando um JSON de alguns megabytes por cópia. Os
    /// fixados não entram na conta: foram marcados justamente para ficar.
    static let maximumEntries = 500

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "clipboard")
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    /// Entradas mais recentes primeiro, fixadas no topo.
    private(set) var entries: [ClipboardEntry] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        loadFromDisk()
    }

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = base.appendingPathComponent("CaptureAI", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("clipboard-history.json")
    }

    /// Registra uma cópia. Ignora vazio e promove repetições em vez de duplicar.
    @discardableResult
    func append(content: String, sourceApp: String? = nil) -> ClipboardEntry? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Copiar de novo o mesmo trecho é o gesto de quem quer usá-lo agora —
        // o lugar dele é no topo, não numa segunda linha idêntica logo abaixo.
        if let index = entries.firstIndex(where: { $0.content == trimmed }) {
            let existing = entries.remove(at: index)
            let promoted = ClipboardEntry(
                id: existing.id,
                content: existing.content,
                kind: existing.kind,
                createdAt: Date(),
                sourceApp: sourceApp ?? existing.sourceApp,
                isPinned: existing.isPinned
            )
            entries.insert(promoted, at: 0)
            sortAndTrim()
            persist()
            return promoted
        }

        let entry = ClipboardEntry(
            content: trimmed,
            kind: ClipboardEntry.classify(trimmed),
            sourceApp: sourceApp
        )
        entries.insert(entry, at: 0)
        sortAndTrim()
        persist()
        return entry
    }

    /// Substitui o conteúdo de um item editado na tela.
    ///
    /// O tipo é recalculado: quem cola um endereço por cima de um texto espera
    /// encontrá-lo depois no filtro "Links".
    func update(id: UUID, content: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let old = entries[index]
        entries[index] = ClipboardEntry(
            id: old.id,
            content: trimmed,
            kind: ClipboardEntry.classify(trimmed),
            createdAt: old.createdAt,
            sourceApp: old.sourceApp,
            isPinned: old.isPinned
        )
        persist()
    }

    func togglePin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
        sortAndTrim()
        persist()
    }

    /// Remove o item e o devolve, para quem quiser oferecer "desfazer".
    @discardableResult
    func delete(id: UUID) -> ClipboardEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = entries.remove(at: index)
        persist()
        return removed
    }

    /// Devolve um item excluído à lista, na posição que a data dele indica.
    func restore(_ entry: ClipboardEntry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        sortAndTrim()
        persist()
    }

    /// Limpa o histórico, preservando o que foi fixado.
    func deleteAll(keepingPinned: Bool = true) {
        let before = entries.count
        entries = keepingPinned ? entries.filter(\.isPinned) : []
        guard entries.count != before else { return }
        persist()
        logger.notice("Área de transferência: histórico limpo (\(before - self.entries.count, privacy: .public) itens).")
    }

    /// Fixados primeiro, depois por data; corta o excedente não fixado.
    private func sortAndTrim() {
        entries.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }

        var unpinned = 0
        entries = entries.filter { entry in
            if entry.isPinned { return true }
            unpinned += 1
            return unpinned <= Self.maximumEntries
        }
    }

    private func loadFromDisk() {
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else {
            entries = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            entries = try decoder.decode([ClipboardEntry].self, from: data)
            sortAndTrim()
        } catch {
            logger.error("Falha ao ler o histórico da área de transferência: \(error.localizedDescription, privacy: .public)")
            entries = []
        }
    }

    private func persist() {
        let snapshot = entries
        let url = fileURL
        let logger = self.logger

        Self.ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                logger.error("Falha ao salvar a área de transferência: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let ioQueue = DispatchQueue(label: "dev.arley.santana.CaptureAI.clipboard.io")
}
