import Foundation
import OSLog

/// Baixa um pacote Core ML direto do Hugging Face com várias conexões em
/// paralelo. Serve o Parakeet TDT e o CTC da substituição de palavras.
///
/// O downloader do FluidAudio busca um arquivo por vez, numa única conexão. O
/// CDN do Hugging Face entrega ~17 MB/s no começo do arquivo e cai para 4–6
/// MB/s no miolo, então uma conexão só rende ~1,4 MB/s no pacote inteiro.
/// Fatiando os arquivos grandes em faixas (`Range`) e baixando 8 de cada vez,
/// o mesmo pacote sai a ~33 MB/s.
///
/// O layout gravado em disco é idêntico ao do FluidAudio, então
/// `AsrModels.load` continua encontrando os modelos (e o cache segue
/// compartilhado com outros apps que usam FluidAudio).
enum ParakeetFastDownloader {

    private static let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "parakeet-download")

    /// O que baixar de um repositório do Hugging Face.
    ///
    /// Os dois modelos têm o mesmo formato — `.mlmodelc` mais um vocabulário na
    /// raiz —, então muda só a lista.
    struct Package: Sendable {
        let name: String
        let repoPath: String
        /// Diretórios `.mlmodelc` exigidos.
        let requiredDirectories: [String]
        /// Arquivos soltos na raiz que o `load` também precisa.
        let requiredRootFiles: [String]

        /// Parakeet TDT 0.6B V3 com encoder int8.
        static let parakeet = Package(
            name: "Parakeet",
            repoPath: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            requiredDirectories: [
                "Preprocessor.mlmodelc/",
                "Encoder.mlmodelc/",
                "Decoder.mlmodelc/",
                "JointDecisionv3.mlmodelc/",
            ],
            requiredRootFiles: ["parakeet_vocab.json"]
        )

        /// CTC 110M usado na substituição de palavras.
        static let ctc110m = Package(
            name: "CTC",
            repoPath: "FluidInference/parakeet-ctc-110m-coreml",
            requiredDirectories: [
                "MelSpectrogram.mlmodelc/",
                "AudioEncoder.mlmodelc/",
            ],
            // `vocab.json` é lido pelo `CtcModels`; `tokenizer.json` pelo
            // `CtcTokenizer`, que tokeniza os termos da substituição. Faltando
            // o segundo, o modelo carrega e só o boosting falha — em silêncio,
            // porque o `modelsExist` do FluidAudio não olha para ele.
            requiredRootFiles: ["vocab.json", "tokenizer.json"]
        )
    }

    /// Faixas simultâneas. Acima disso o ganho satura e o CDN começa a limitar.
    private static let maxConcurrentSegments = 8

    /// Tamanho de cada faixa. Arquivos menores que isso vão numa requisição só.
    private static let segmentSize: Int64 = 8 * 1024 * 1024

    private static let maxAttemptsPerSegment = 3

    // MARK: - `.partial` desta execução

    /// Os `.partial` criados por **este** download, e o único conjunto que
    /// podemos apagar com segurança.
    ///
    /// O diretório de cache é compartilhado com outros apps que usam FluidAudio
    /// (o Spokenly, por exemplo), e o `FileDownloader` dele usa a mesma extensão
    /// `.partial` — só que ali ela é ponto de retomada por `Range`, projetado
    /// para sobreviver inclusive à troca de processo. Varrer o diretório por
    /// extensão jogaria fora o download de outro app.
    private static let activePartialsLock = NSLock()
    nonisolated(unsafe) private static var activePartials: Set<URL> = []

    private static func trackPartial(_ url: URL) {
        activePartialsLock.lock()
        activePartials.insert(url)
        activePartialsLock.unlock()
    }

    private static func untrackPartials(_ urls: [URL]) {
        activePartialsLock.lock()
        for url in urls {
            activePartials.remove(url)
        }
        activePartialsLock.unlock()
    }

    /// Apaga os `.partial` desta execução.
    ///
    /// Síncrono de propósito: o único chamador é `applicationWillTerminate`, e
    /// ali qualquer `Task` ficaria na fila enquanto o processo morre.
    static func purgeActivePartials() {
        activePartialsLock.lock()
        let urls = activePartials
        activePartials = []
        activePartialsLock.unlock()

        guard !urls.isEmpty else { return }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        logger.notice("Descartados \(urls.count) `.partial` do download interrompido.")
    }

    struct RemoteFile: Sendable {
        let path: String
        let size: Int64
    }

    enum DownloadError: LocalizedError {
        case invalidResponse(String)
        case unexpectedStatus(path: String, status: Int)
        case sizeMismatch(path: String, expected: Int64, got: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let detail):
                return "Resposta inválida do Hugging Face: \(detail)"
            case .unexpectedStatus(let path, let status):
                return "Falha ao baixar \(path) (HTTP \(status))"
            case .sizeMismatch(let path, let expected, let got):
                return "Arquivo \(path) veio incompleto (esperado \(expected) bytes, recebido \(got))"
            }
        }
    }

    /// Acumula os bytes já recebidos entre as faixas concorrentes.
    private actor ByteCounter {
        private var received: Int64
        private let total: Int64
        private let report: @Sendable (Int64, Int64) -> Void

        init(initial: Int64, total: Int64, report: @escaping @Sendable (Int64, Int64) -> Void) {
            self.received = initial
            self.total = total
            self.report = report
        }

        func add(_ bytes: Int64) {
            received += bytes
            report(received, total)
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        // O padrão (6) estrangularia as faixas concorrentes.
        configuration.httpMaximumConnectionsPerHost = maxConcurrentSegments * 2
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// Baixa tudo que falta para `cacheDirectory` e reporta `(recebidos, total)`.
    ///
    /// Só a fase de rede acontece aqui; a compilação Core ML fica para o
    /// primeiro uso do modelo.
    static func download(
        _ package: Package,
        to cacheDirectory: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        let remoteFiles = try await listRequiredFiles(package, session: session)
        let totalBytes = remoteFiles.reduce(0) { $0 + $1.size }

        // Arquivos já íntegros em disco não são baixados de novo.
        var pending: [RemoteFile] = []
        var alreadyOnDisk: Int64 = 0
        for file in remoteFiles {
            let destination = cacheDirectory.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: destination.path),
               localSize(of: destination) == file.size {
                alreadyOnDisk += file.size
            } else {
                pending.append(file)
            }
        }

        progress(alreadyOnDisk, totalBytes)
        guard !pending.isEmpty else { return }

        logger.notice(
            "Baixando \(pending.count) arquivo(s) do \(package.name, privacy: .public) (\(totalBytes / 1_048_576) MB no total)."
        )

        let counter = ByteCounter(initial: alreadyOnDisk, total: totalBytes, report: progress)
        let segments = try prepareSegments(for: pending, in: cacheDirectory, repoPath: package.repoPath)

        do {
            try await runSegments(segments, session: session, counter: counter)
            try Task.checkCancellation()
            try commit(pending, in: cacheDirectory)
        } catch {
            // `.partial` pré-alocado é esparso e confundiria o cálculo de espaço
            // em disco; como o pacote inteiro leva segundos, recomeçar é barato.
            discardPartials(for: pending, in: cacheDirectory)
            throw error
        }
    }

    // MARK: - Listagem remota

    private struct TreeItem: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private static func listRequiredFiles(
        _ package: Package,
        session: URLSession
    ) async throws -> [RemoteFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(package.repoPath)/tree/main?recursive=true") else {
            throw DownloadError.invalidResponse("URL da árvore do repositório")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse("resposta não-HTTP na listagem")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.unexpectedStatus(path: "tree/main", status: http.statusCode)
        }

        let items = try JSONDecoder().decode([TreeItem].self, from: data)
        let files = items.compactMap { item -> RemoteFile? in
            guard item.type == "file" else { return nil }
            let isRequired =
                package.requiredDirectories.contains { item.path.hasPrefix($0) }
                || package.requiredRootFiles.contains(item.path)
            return isRequired ? RemoteFile(path: item.path, size: item.size ?? 0) : nil
        }

        guard !files.isEmpty else {
            throw DownloadError.invalidResponse("nenhum arquivo do \(package.name) encontrado no repositório")
        }
        return files
    }

    // MARK: - Faixas

    private struct Segment: Sendable {
        let repoPath: String
        let path: String
        let partial: URL
        /// `nil` baixa o arquivo inteiro numa requisição sem `Range`.
        let range: (lower: Int64, upper: Int64)?
        let byteCount: Int64
    }

    /// Cria os `.partial` com o tamanho final e fatia os arquivos grandes.
    private static func prepareSegments(
        for files: [RemoteFile],
        in cacheDirectory: URL,
        repoPath: String
    ) throws -> [Segment] {
        var segments: [Segment] = []

        for file in files {
            let destination = cacheDirectory.appendingPathComponent(file.path)
            let partial = destination.appendingPathExtension("partial")
            try FileManager.default.createDirectory(
                at: partial.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            trackPartial(partial)

            // O Hugging Face responde 500 em arquivos vazios; criar local resolve.
            if file.size == 0 {
                continue
            }

            if file.size <= segmentSize {
                segments.append(
                    Segment(repoPath: repoPath, path: file.path, partial: partial, range: nil, byteCount: file.size)
                )
                continue
            }

            // Reserva o tamanho final para as faixas escreverem em paralelo.
            let handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: UInt64(file.size))
            try handle.close()

            var lower: Int64 = 0
            while lower < file.size {
                let upper = min(lower + segmentSize, file.size) - 1
                segments.append(
                    Segment(
                        repoPath: repoPath,
                        path: file.path,
                        partial: partial,
                        range: (lower, upper),
                        byteCount: upper - lower + 1
                    )
                )
                lower = upper + 1
            }
        }

        // Faixas maiores primeiro: as conexões terminam mais parelhas no fim.
        return segments.sorted { $0.byteCount > $1.byteCount }
    }

    private static func runSegments(
        _ segments: [Segment],
        session: URLSession,
        counter: ByteCounter
    ) async throws {
        var next = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            let initial = min(maxConcurrentSegments, segments.count)
            for _ in 0..<initial {
                let segment = segments[next]
                next += 1
                group.addTask { try await fetch(segment, session: session, counter: counter) }
            }

            while try await group.next() != nil {
                guard next < segments.count else { continue }
                try Task.checkCancellation()
                let segment = segments[next]
                next += 1
                group.addTask { try await fetch(segment, session: session, counter: counter) }
            }
        }
    }

    private static func fetch(
        _ segment: Segment,
        session: URLSession,
        counter: ByteCounter
    ) async throws {
        var lastError: Error?

        for attempt in 1...maxAttemptsPerSegment {
            do {
                try Task.checkCancellation()
                let data = try await requestSegment(segment, session: session)
                try Task.checkCancellation()

                let handle = try FileHandle(forWritingTo: segment.partial)
                defer { try? handle.close() }
                if let range = segment.range {
                    try handle.seek(toOffset: UInt64(range.lower))
                }
                try handle.write(contentsOf: data)

                await counter.add(Int64(data.count))
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // URLSession devolve `URLError.cancelled` quando o grupo é
                // cancelado; sem isso as tentativas continuariam após o cancelamento.
                if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                guard attempt < maxAttemptsPerSegment else { break }
                logger.warning(
                    "Faixa de \(segment.path, privacy: .public) falhou (tentativa \(attempt)): \(error.localizedDescription, privacy: .public)"
                )
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }

        throw lastError ?? DownloadError.invalidResponse(segment.path)
    }

    private static func requestSegment(_ segment: Segment, session: URLSession) async throws -> Data {
        let encodedPath =
            segment.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment.path
        guard let url = URL(string: "https://huggingface.co/\(segment.repoPath)/resolve/main/\(encodedPath)") else {
            throw DownloadError.invalidResponse(segment.path)
        }

        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = segment.range {
            request.setValue("bytes=\(range.lower)-\(range.upper)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse(segment.path)
        }

        if segment.range != nil {
            // Sem 206 as faixas se sobrescreveriam; melhor falhar e tentar de novo.
            guard http.statusCode == 206 else {
                throw DownloadError.unexpectedStatus(path: segment.path, status: http.statusCode)
            }
        } else {
            guard (200..<300).contains(http.statusCode) else {
                throw DownloadError.unexpectedStatus(path: segment.path, status: http.statusCode)
            }
        }

        guard Int64(data.count) == segment.byteCount else {
            throw DownloadError.sizeMismatch(
                path: segment.path,
                expected: segment.byteCount,
                got: Int64(data.count)
            )
        }
        return data
    }

    // MARK: - Publicação no cache

    /// Confere o tamanho de cada `.partial` e move para o nome definitivo.
    private static func commit(_ files: [RemoteFile], in cacheDirectory: URL) throws {
        for file in files {
            let destination = cacheDirectory.appendingPathComponent(file.path)
            let partial = destination.appendingPathExtension("partial")

            let size = localSize(of: partial)
            guard size == file.size else {
                throw DownloadError.sizeMismatch(path: file.path, expected: file.size, got: size)
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            untrackPartials([partial])
        }
    }

    private static func discardPartials(for files: [RemoteFile], in cacheDirectory: URL) {
        let partials = files.map {
            cacheDirectory.appendingPathComponent($0.path).appendingPathExtension("partial")
        }
        for partial in partials {
            try? FileManager.default.removeItem(at: partial)
        }
        untrackPartials(partials)
    }

    private static func localSize(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return 0
        }
        return size
    }
}
