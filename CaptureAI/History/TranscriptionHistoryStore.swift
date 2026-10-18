import Foundation
import Observation
import OSLog

/// Uma transcrição salva no histórico local.
struct TranscriptionHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let durationSeconds: TimeInterval?

    /// Nome do `.m4a` guardado, quando "manter gravações" estava ligado.
    ///
    /// Guardamos o nome, não o caminho: a pasta é derivada do container do app,
    /// e um caminho absoluto gravado hoje apontaria para o lugar errado se o
    /// container mudasse. Entradas antigas não têm o campo e decodificam como
    /// `nil` — é só não mostrar o play nelas.
    let audioFileName: String?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        durationSeconds: TimeInterval? = nil,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.audioFileName = audioFileName
    }

    /// Onde o áudio está agora, se ainda estiver lá.
    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return RecordingStorage.directoryURL.appendingPathComponent(audioFileName)
    }
}

/// Persiste o histórico de transcrições em JSON (Application Support).
@Observable
@MainActor
final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "history")
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    /// Entradas mais recentes primeiro.
    private(set) var entries: [TranscriptionHistoryEntry] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        loadFromDisk()
        removeOrphanRecordings()
    }

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = base.appendingPathComponent("CaptureAI", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("transcription-history.json")
    }

    /// Adiciona uma entrada no topo. Ignora texto vazio.
    ///
    /// - Returns: `true` se a entrada foi criada.
    @discardableResult
    func append(
        text: String,
        durationSeconds: TimeInterval? = nil,
        audioFileName: String? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let entry = TranscriptionHistoryEntry(
            text: trimmed,
            durationSeconds: durationSeconds,
            audioFileName: audioFileName
        )
        entries.insert(entry, at: 0)
        persist()
        logger.notice("Histórico: +1 entrada (total \(self.entries.count, privacy: .public)).")
        return true
    }

    /// Remove a entrada e o áudio ligado a ela.
    ///
    /// O áudio vai junto porque foi guardado **por causa** desta ditagem: mantê-lo
    /// órfão deixaria um arquivo que ninguém mais consegue relacionar a nada.
    func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        deleteAudio(of: removed)
        persist()
    }

    func deleteAll() {
        guard !entries.isEmpty else { return }
        entries.forEach(deleteAudio)
        entries = []
        persist()
        // "Tudo" inclui o áudio solto que nenhuma entrada referencia — sobra
        // de versões anteriores, que guardavam o áudio de ditagens sem fala.
        removeOrphanRecordings()
        logger.notice("Histórico limpo.")
    }

    /// Apaga os áudios da pasta de gravações que nenhuma entrada referencia.
    ///
    /// Roda ao abrir o app também: com o histórico já vazio, o "Excluir tudo"
    /// fica desativado e nunca alcançaria esses arquivos. Ao abrir não há
    /// ditagem em andamento, então nenhum áudio pendente é tocado.
    func removeOrphanRecordings() {
        let folder = RecordingStorage.directoryURL
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        let referenced = Set(entries.compactMap(\.audioFileName))
        var removed = 0
        for file in files where ["m4a", "wav", "caf"].contains(file.pathExtension.lowercased()) {
            guard !referenced.contains(file.lastPathComponent) else { continue }
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            logger.notice("Gravações órfãs apagadas: \(removed, privacy: .public).")
        }
    }

    private func deleteAudio(of entry: TranscriptionHistoryEntry) {
        guard let url = entry.audioURL, fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Falha ao apagar áudio do histórico: \(error.localizedDescription, privacy: .public)")
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
            let loaded = try decoder.decode([TranscriptionHistoryEntry].self, from: data)
            entries = loaded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            logger.error("Falha ao ler histórico: \(error.localizedDescription, privacy: .public)")
            entries = []
        }
    }

    /// Grava fora do MainActor, numa fila serial.
    ///
    /// O JSON é do histórico **inteiro** e cresce a cada ditagem; feito de forma
    /// síncrona aqui, o custo entrava direto na latência entre a transcrição
    /// ficar pronta e o texto aparecer no campo. A fila serial garante que a
    /// última gravação enfileirada é a que fica no disco.
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
                logger.error("Falha ao salvar histórico: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let ioQueue = DispatchQueue(label: "dev.arley.santana.CaptureAI.history.io")
}
