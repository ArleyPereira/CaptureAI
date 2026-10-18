import Foundation
import Observation
import OSLog

/// Erro de importação com texto pronto para a UI.
///
/// Importação que falha em silêncio deixa o usuário achando que cadastrou —
/// por isso todo caminho de erro aqui tem mensagem. Fica fora do store para não
/// herdar o isolamento de `@MainActor`, já que `errorDescription` é `nonisolated`.
enum WordReplacementImportError: LocalizedError {
    case unreadable
    case unrecognizedFormat
    case noValidEntries

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Não foi possível ler o arquivo."
        case .unrecognizedFormat:
            return "Formato não reconhecido. Use { \"terms\": [{ \"text\", \"aliases\" }] } ou [{ \"original\", \"replacement\" }]."
        case .noValidEntries:
            return "Nenhum par válido no arquivo — verifique o tamanho mínimo de \(WordReplacement.minimumLength) caracteres."
        }
    }
}

/// Persiste a lista de substituições em JSON (Application Support).
///
/// Espelha o `TranscriptionHistoryStore`: leitura síncrona no init, gravação
/// numa fila serial fora do MainActor.
@Observable
@MainActor
final class WordReplacementStore {
    static let shared = WordReplacementStore()

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "word-replacements")
    private let fileManager: FileManager

    /// Na ordem em que o usuário organizou — é a ordem enviada ao motor.
    private(set) var items: [WordReplacement] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        loadFromDisk()
    }

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = base.appendingPathComponent("CaptureAI", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("word-replacements.json")
    }

    // MARK: - Validação

    /// Confere um par antes de gravar.
    ///
    /// - Parameter ignoring: id do item em edição, para ele não colidir consigo mesmo.
    func validate(
        original: String,
        replacement: String,
        ignoring id: UUID? = nil
    ) -> WordReplacementValidationError? {
        let variants = WordReplacement.parseOriginals(original)
        let cleanReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !variants.isEmpty, !cleanReplacement.isEmpty else {
            return .emptyField
        }
        // Cada variante é medida sozinha: uma linha curta no meio da lista
        // ("brand, or, brant") passaria despercebida se olhássemos o campo todo.
        guard variants.allSatisfy({ $0.count >= WordReplacement.minimumLength }),
              cleanReplacement.count >= WordReplacement.minimumLength else {
            return .tooShort(minimum: WordReplacement.minimumLength)
        }

        // Duplicata é por **variante**: duas linhas que reivindicam a mesma
        // origem se contradizem, mesmo que o resto do campo seja diferente.
        // Comparação sem diferenciar maiúsculas porque o modelo não é
        // consistente na capitalização.
        let taken = Set(
            items.filter { $0.id != id }
                .flatMap(\.originals)
                .map { $0.lowercased() }
        )
        if let clash = variants.first(where: { taken.contains($0.lowercased()) }) {
            return .duplicated(original: clash)
        }
        return nil
    }

    // MARK: - CRUD

    /// Cria um par no fim da lista. Devolve o erro quando recusa.
    @discardableResult
    func add(original: String, replacement: String) -> WordReplacementValidationError? {
        if let error = validate(original: original, replacement: replacement) {
            return error
        }
        let item = WordReplacement(
            original: WordReplacement.normalizedOriginal(original),
            replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
            sortIndex: items.count
        )
        items.append(item)
        persist()
        logger.notice("Substituições: +1 (total \(self.items.count, privacy: .public)).")
        return nil
    }

    @discardableResult
    func update(id: UUID, original: String, replacement: String) -> WordReplacementValidationError? {
        if let error = validate(original: original, replacement: replacement, ignoring: id) {
            return error
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].original = WordReplacement.normalizedOriginal(original)
        items[index].replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
        return nil
    }

    func delete(id: UUID) {
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else { return }
        reindex()
        persist()
    }

    func moveToTop(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let item = items.remove(at: index)
        items.insert(item, at: 0)
        reindex()
        persist()
    }

    func moveToBottom(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index < items.count - 1 else { return }
        let item = items.remove(at: index)
        items.append(item)
        reindex()
        persist()
    }

    /// Coloca `id` na posição que `targetID` ocupa agora.
    ///
    /// Só mexe na memória: durante um arraste isto é chamado a cada linha que o
    /// cursor cruza, e gravar em disco a cada passo seria dezenas de escritas
    /// por gesto. Quem fecha é `commitReorder()`, no soltar.
    func reorder(id: UUID, toIndexOf targetID: UUID) {
        guard id != targetID,
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    /// Grava a ordem alcançada pelo arraste.
    func commitReorder() {
        reindex()
        persist()
    }

    // MARK: - Importação

    /// Formato simples: `[{ "original": "brand", "replacement": "branch" }]`
    private struct SimpleEntry: Decodable {
        let original: String
        let replacement: String
    }

    /// Formato do FluidAudio: `{ "terms": [{ "text": "branch", "aliases": ["brand"] }] }`
    private struct FluidAudioFile: Decodable {
        struct Term: Decodable {
            let text: String
            let aliases: [String]?
        }
        let terms: [Term]
    }

    /// Importa um JSON para a lista interna, copiando o conteúdo.
    ///
    /// O arquivo escolhido não vira fonte da verdade: depois de importar, ele
    /// pode sumir sem afetar nada.
    ///
    /// - Returns: quantos pares entraram.
    @discardableResult
    func importFrom(url: URL) throws -> Int {
        // Arquivo fora do container precisa de permissão explícita quando vem
        // do painel de abrir.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            throw WordReplacementImportError.unreadable
        }

        let decoder = JSONDecoder()
        var candidates: [(original: String, replacement: String)] = []

        if let file = try? decoder.decode(FluidAudioFile.self, from: data) {
            // Os aliases de um termo cabem numa linha só, separados por vírgula
            // — é a mesma forma que o campo aceita ao digitar.
            candidates = file.terms.compactMap { term in
                let aliases = term.aliases ?? []
                guard !aliases.isEmpty else { return nil }
                return (original: aliases.joined(separator: ", "), replacement: term.text)
            }
        } else if let entries = try? decoder.decode([SimpleEntry].self, from: data) {
            candidates = entries.map { (original: $0.original, replacement: $0.replacement) }
        } else {
            throw WordReplacementImportError.unrecognizedFormat
        }

        // Passa pela mesma validação do cadastro manual: um arquivo não deve
        // conseguir inserir o que a UI recusaria.
        var imported = 0
        for candidate in candidates
        where add(original: candidate.original, replacement: candidate.replacement) == nil {
            imported += 1
        }

        guard imported > 0 else { throw WordReplacementImportError.noValidEntries }
        logger.notice("Substituições importadas: \(imported, privacy: .public).")
        return imported
    }

    // MARK: - Persistência

    /// Realinha `sortIndex` com a posição real depois de mover ou remover.
    private func reindex() {
        for index in items.indices {
            items[index].sortIndex = index
        }
    }

    private func loadFromDisk() {
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else {
            items = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([WordReplacement].self, from: data)
            items = loaded.sorted { $0.sortIndex < $1.sortIndex }
        } catch {
            logger.error("Falha ao ler substituições: \(error.localizedDescription, privacy: .public)")
            items = []
        }
    }

    private func persist() {
        let snapshot = items
        let url = fileURL
        let logger = self.logger

        Self.ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                logger.error("Falha ao salvar substituições: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let ioQueue = DispatchQueue(label: "dev.arley.santana.CaptureAI.wordreplacements.io")
}
