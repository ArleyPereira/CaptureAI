import AppKit
import Foundation
import Observation
import OSLog

/// Observa a área de transferência do sistema e alimenta o histórico.
///
/// O `NSPasteboard` não avisa quando muda — não existe notificação, nem KVO.
/// O único caminho é comparar `changeCount` de tempos em tempos, que é o que
/// todo gerenciador de área de transferência no macOS faz. A leitura é barata:
/// `changeCount` é um inteiro, e só vamos ao conteúdo quando ele muda.
@Observable
@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    /// Meio segundo é curto o bastante para a cópia já estar na lista quando a
    /// pessoa abre a janela, e longo o bastante para o custo desaparecer: são
    /// duas leituras de inteiro por segundo.
    private static let pollInterval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private let store: ClipboardHistoryStore
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "clipboard")

    private var timer: Timer?
    private var lastChangeCount: Int

    /// Conteúdo que o próprio app acabou de escrever e não deve registrar.
    ///
    /// A inserção do ditado passa pela área de transferência (escreve, ⌘V,
    /// restaura). Sem isto, cada ditagem apareceria aqui como se o usuário a
    /// tivesse copiado, e a restauração entraria como uma segunda cópia.
    private var suppressed: Set<String> = []

    private(set) var isRunning = false

    init(
        pasteboard: NSPasteboard = .general,
        store: ClipboardHistoryStore = .shared
    ) {
        self.pasteboard = pasteboard
        self.store = store
        // Começa do estado atual: o que já estava na área de transferência
        // antes de o app abrir não é uma cópia que presenciamos.
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = pasteboard.changeCount

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // `.common` mantém a checagem viva enquanto menus estão abertos ou uma
        // lista está sendo arrastada — justamente quando se copia algo.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.notice("Monitor da área de transferência ligado.")
    }

    func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        isRunning = false
        logger.notice("Monitor da área de transferência desligado.")
    }

    /// Marca um texto como escrito por nós, para o monitor não registrá-lo.
    func suppress(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        suppressed.insert(trimmed)
    }

    /// Escreve na área de transferência sem que a escrita volte como item novo.
    func copyWithoutRecording(_ content: String) {
        suppress(content)
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Conteúdo marcado como de passagem não é uma cópia do usuário.
        // Quem marca assim é o próprio app, ao inserir uma ditagem via ⌘V:
        // sem isto, cada ditado apareceria aqui como item copiado.
        if pasteboard.data(forType: .transient) != nil { return }

        guard let content = pasteboard.string(forType: .string) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if suppressed.remove(trimmed) != nil { return }

        store.append(content: trimmed, sourceApp: frontmostAppName())
    }

    /// Quem estava na frente no instante da cópia.
    ///
    /// Vale só como rótulo: entre a cópia e a checagem o foco pode ter mudado,
    /// e nesse caso o nome sai errado. É por isso que a origem é mostrada
    /// discretamente, e nunca usada para decidir nada.
    private func frontmostAppName() -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        guard let name = app?.localizedName, name != "CaptureAI" else { return nil }
        return name
    }
}
