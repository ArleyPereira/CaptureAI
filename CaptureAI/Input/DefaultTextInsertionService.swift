import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

/// Estratégia usada na última inserção bem-sucedida (diagnóstico).
enum InsertionMethod: String {
    case accessibility = "Accessibility"
    case unicodeTyping = "digitação Unicode"
    case clipboardHID = "⌘V (HID)"
    case clipboardSession = "⌘V (sessão)"
    case clipboardSystemEvents = "⌘V (System Events)"
}

/// Insere texto no campo em foco de qualquer aplicativo.
///
/// Três caminhos, nesta ordem:
/// 1. Accessibility direto — apps nativos (Notas, TextEdit, Safari).
/// 2. Digitação Unicode sintética — Electron/Chromium (Cursor, VS Code, Chrome).
///    Entrega o texto como entrada de teclado, **sem encostar na área de
///    transferência** do usuário.
/// 3. Clipboard + ⌘V — último recurso; o conteúdo anterior é sempre restaurado.
///
/// A etapa 1 é sempre **verificada por releitura**: apps Electron respondem
/// `success` ao `AXUIElementSetAttributeValue` sem alterar o campo, e confiar
/// nesse retorno impedia os fallbacks de rodar.
final class DefaultTextInsertionService: TextInsertionService, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "insertion")
    private let accessibilityService: any AccessibilityServiceProtocol
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Papéis em que a escrita direta via AX faz sentido tentar.
    private let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    private(set) var lastMethod: InsertionMethod?

    init(accessibilityService: any AccessibilityServiceProtocol) {
        self.accessibilityService = accessibilityService
    }

    func insert(text: String) async throws {
        try await performInsertion(text: text, captured: nil)
    }

    func insert(text: String, into captured: FocusedElement) async throws {
        try await performInsertion(text: text, captured: captured)
    }

    // MARK: - Núcleo

    private func performInsertion(text: String, captured: FocusedElement?) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceInputError.emptyTranscription
        }

        guard accessibilityService.isTrusted() else {
            logger.error("Sem confiança de Acessibilidade; inserção abortada.")
            throw VoiceInputError.accessibilityPermissionDenied
        }

        // O atalho é ⇧ Tab: se o Shift ainda estiver baixo, o ⌘V vira ⌘⇧V e a
        // digitação sai com caracteres errados. Uma vez só: as tentativas de
        // inserção abaixo não voltam a mexer no teclado físico.
        await waitForClearModifiers()

        // Depois de uma transcrição longa o app alvo pode ter perdido o
        // frontmost; reativar antes de reler o foco evita alvo fantasma.
        //
        // Só vale quando o que capturamos é mesmo um campo de texto. Se a
        // gravação começou sem foco em nada editável (a mesa, o Finder) e o
        // usuário clicou num input **durante** a fala, reativar o app capturado
        // roubaria de volta o foco que ele acabou de escolher — e aí lemos como
        // "sem campo editável" uma janela que nós mesmos trouxemos para frente.
        // Um capturado não-editável nunca é aceito como alvo no `guard` abaixo,
        // então ativá-lo não traz ganho nenhum.
        if let captured, resolveEditableTarget(from: captured) != nil {
            try? await activateAndWait(pid: captured.processID)
        }

        let liveTarget = await resolveTargetWithRetry()
        let candidates = [captured, liveTarget].compactMap { $0 }

        // Exige um alvo genuinamente editável. Eventos de teclado/clipboard são
        // globais — não ficam restritos ao nó AX que escolhemos — então, sem
        // confirmação de que o alvo é mesmo um campo de texto, não dá para
        // confiar na verificação (ela checaria o nó errado) nem saber se já
        // inserimos em algum lugar. Melhor não tentar do que arriscar duplicar
        // a ditagem num campo invisível para a Acessibilidade.
        guard let target = candidates.compactMap({ resolveEditableTarget(from: $0) }).first else {
            let summary = candidates.map(\.summary).joined(separator: ", ")
            logger.notice("Sem campo editável em foco (candidatos: \(summary.isEmpty ? "nenhum" : summary, privacy: .public)).")
            throw VoiceInputError.noFocusedElement
        }

        logDiagnostics(target: target, captured: captured, live: liveTarget)

        let chromiumLike = isChromiumLike(target)
        let bundleID = NSRunningApplication(processIdentifier: target.processID)?
            .bundleIdentifier ?? "desconhecido"
        // Nunca logamos a ditagem em si — só o tamanho, que é a variável que
        // separa o caso que funciona do que falha.
        logger.notice(
            """
            Inserção: \(trimmed.count, privacy: .public) chars, \
            app \(bundleID, privacy: .public), papel \(target.role ?? "—", privacy: .public), \
            chromiumLike=\(chromiumLike, privacy: .public)
            """
        )

        // No Chromium/Electron o `AXSelectedText` pode “aceitar” e até inserir
        // sem o valor AX refletir direito. Se seguirmos para ⌘V/Unicode depois,
        // o texto entra duas vezes e o diálogo de falha ainda aparece.
        //
        // Em campo nativo, porém, escrever no AX é síncrono e não toca no
        // clipboard: é o caminho mais rápido que existe aqui.
        if !chromiumLike {
            if insertViaAccessibilityVerified(trimmed, into: target) {
                lastMethod = .accessibility
                logger.notice("Inserido via Accessibility em \(target.summary, privacy: .public)")
                return
            }
            logger.notice("Accessibility (AXSelectedText) não confirmou; seguindo para ⌘V.")
        }

        // O estado do campo tem que ser lido **antes** da escrita; a auditoria
        // em si só começa depois, senão a nossa própria digitação conta como
        // "usuário digitou" e encerra a checagem por engano.
        let baseline = fieldSnapshot(of: target)

        // Nunca perguntamos ao AX "o texto entrou?" para decidir. O que sabemos
        // com certeza é se o evento saiu; se nenhum mecanismo aceitou, aí sim
        // houve falha real.
        //
        // A ORDEM depende do app, e isso foi medido: em 13 ditagens no Cursor,
        // o ⌘V não chegou ao campo em ~1 de cada 3. Todo o resto estava
        // correto — clipboard íntegro nos três checkpoints, app em foco, sem
        // modificador preso —, então o evento é aceito pelo sistema e descartado
        // pelo app. Aumentar a pausa entre os eventos de 8 para 18 ms não mudou.
        //
        // A digitação Unicode era o caminho principal antes do PR de latência e
        // não tinha esse problema; o ⌘V entrou para ganhar tempo e trouxe a
        // falha junto. Nos apps Electron ela volta a ser a primeira opção.
        if chromiumLike {
            if await insertViaUnicodeTyping(trimmed, target: target) {
                lastMethod = .unicodeTyping
                logger.notice("Inserido via digitação Unicode.")
                auditInsertion(target: target, expected: trimmed, baseline: baseline)
                return
            }
            logger.notice("Digitação não pôde ser enviada; tentando clipboard + ⌘V.")
        }

        if await insertViaClipboardPaste(trimmed, target: target) {
            logger.notice("Inserido via clipboard + ⌘V.")
            // Só agora: a partir daqui qualquer tecla é mesmo do usuário.
            auditInsertion(target: target, expected: trimmed, baseline: baseline)
            return
        }

        // Cada mecanismo já foi tentado no máximo uma vez, então não há como
        // duplicar: chegar aqui significa que nenhum evento saiu.
        if !chromiumLike {
            logger.notice("Colagem não pôde ser enviada; tentando digitação Unicode.")
            if await insertViaUnicodeTyping(trimmed, target: target) {
                lastMethod = .unicodeTyping
                logger.notice("Inserido via digitação Unicode.")
                auditInsertion(target: target, expected: trimmed, baseline: baseline)
                return
            }
        }

        logger.error("Nenhum mecanismo de entrega funcionou; oferecendo pela barra de resgate.")
        throw VoiceInputError.textInsertionFailed
    }

    /// Acompanha o campo por alguns segundos **depois** da inserção retornar.
    ///
    /// Diagnóstico puro: não interfere no fluxo nem no tempo dele — justamente
    /// porque o tempo é a variável suspeita quando a ditagem é longa. Registra o
    /// tamanho do valor AX ao longo do tempo, então dá para distinguir três
    /// casos que hoje terminam iguais no log: o texto entrou na hora, entrou
    /// tarde (depois de já termos devolvido o clipboard), ou nunca entrou.
    /// Estado do campo antes da escrita, para a auditoria comparar depois.
    private func fieldSnapshot(of target: FocusedElement) -> (placeholder: String?, length: Int) {
        let placeholder = axPlaceholder(of: target.axElement)
        let raw = copyStringAttribute(target.axElement, kAXValueAttribute as CFString)
        return (placeholder, strippingPlaceholder(from: raw, placeholder: placeholder).count)
    }

    private func auditInsertion(
        target: FocusedElement,
        expected: String,
        baseline: (placeholder: String?, length: Int)
    ) {
        let placeholder = baseline.placeholder
        let baselineLength = baseline.length
        let expectedCount = expected.count

        // A contagem de "usuário digitou" começa **aqui**, depois de o nosso ⌘V
        // já ter sido enviado. Medir a partir de antes fazia a nossa própria
        // tecla contar como digitação do usuário e encerrar a auditoria por
        // engano — foi assim que uma falha real passou sem barra de resgate.
        let start = DispatchTime.now()

        Task { [weak self] in
            guard let self else { return }
            var previous = -1

            for delay in [400, 800, 1_500, 3_000] {
                let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                try? await Task.sleep(for: .milliseconds(max(0, delay - elapsedMs)))

                // Do momento em que o usuário digita, o campo é dele: apagar a
                // ditagem recém-inserida não é falha de inserção.
                if self.userTypedSince(start) {
                    self.logger.notice("Auditoria encerrada: o usuário editou o campo.")
                    return
                }

                // Mesmo cuidado da verificação: preferir o foco atual, porque o
                // elemento capturado pode ter sido descartado pelo editor.
                let live = try? self.accessibilityService.focusedElement()
                let element = (live?.processID == target.processID ? live?.axElement : nil) ?? target.axElement
                let raw = self.copyStringAttribute(element, kAXValueAttribute as CFString)
                let current = self.strippingPlaceholder(from: raw ?? "", placeholder: placeholder)

                // Só loga quando algo muda, para não encher o Console.
                if current.count != previous {
                    previous = current.count
                    self.logger.notice(
                        """
                        Auditoria +\(delay, privacy: .public) ms: campo \(current.count, privacy: .public) chars \
                        (era \(baselineLength, privacy: .public), esperado +\(expectedCount, privacy: .public))
                        """
                    )
                }

                if current.contains(expected) { return }

                // O `AXValue` do nó focado não é a última palavra: no Chromium o
                // texto de um contenteditable mora nos filhos, e esse nó pode
                // continuar reportando o placeholder. Procurar na subárvore
                // encontra o texto onde ele realmente está.
                if let node = self.findDictation(expected, startingAt: element) {
                    self.logger.notice(
                        "Auditoria +\(delay, privacy: .public) ms: ditagem encontrada em \(node, privacy: .public)."
                    )
                    return
                }
            }

            // Não encontrar a ditagem **não** prova que ela não entrou, e por
            // isso este caminho não abre a barra de resgate.
            //
            // O editor do VS Code e o do Cursor (ambos Monaco) publicam um
            // campo vazio no AX: `AXValue` 0, `AXNumberOfCharacters` 0 e
            // `AXChildren` 0, com o texto visível na tela. "Não entrou" e "o
            // app não conta o que tem" produzem exatamente a mesma leitura, e
            // tratar as duas como falha gerava barra falsa em toda ditagem
            // nesses editores.
            //
            // Fica só como registro: sem isso não temos como medir a taxa real
            // de falha de entrega, que continua sendo uma incógnita.
            self.logger.error(
                """
                Auditoria: a ditagem de \(expectedCount, privacy: .public) chars não foi encontrada na árvore \
                do campo em 3 s. Pode ser falha de entrega ou app que não expõe o conteúdo — não dá para distinguir.
                """
            )
            self.dumpTextAttributes(of: target, expected: expected)
        }
    }

    /// Procura a ditagem no nó, no ancestral editável e na subárvore de ambos.
    ///
    /// O dump AX do chat do Cursor mostrou por que olhar só o nó focado não
    /// basta: ele reporta `AXValue` e `AXNumberOfCharacters` iguais a 15 (o
    /// placeholder) com 609 caracteres visíveis na tela, e traz
    /// `AXChildren` e `AXHighestEditableAncestor`. O texto do contenteditable
    /// está em outro nó da árvore, não naquele.
    ///
    /// - Returns: descrição de onde achou, ou `nil` se não achou em lugar nenhum.
    private func findDictation(_ expected: String, startingAt element: AXUIElement) -> String? {
        var roots: [(label: String, element: AXUIElement)] = [("nó focado", element)]

        // O contenteditable inteiro costuma agregar o texto que o nó focado não
        // agrega, então ele entra na busca como raiz alternativa.
        for attribute in ["AXHighestEditableAncestor", "AXEditableAncestor"] {
            if let ancestor = copyElementAttribute(element, attribute as CFString) {
                roots.append((attribute, ancestor))
            }
        }

        var budget = Self.subtreeSearchBudget
        for root in roots {
            if let path = search(expected, in: root.element, depth: 0, budget: &budget) {
                return path.isEmpty ? root.label : "\(root.label) → \(path)"
            }
        }
        return nil
    }

    /// Quantos nós a busca pode visitar, somando todas as raízes.
    ///
    /// A árvore de um Electron é grande; o teto mantém a auditoria barata
    /// mesmo rodando quatro vezes por ditagem.
    private static let subtreeSearchBudget = 400

    private func search(
        _ expected: String,
        in element: AXUIElement,
        depth: Int,
        budget: inout Int
    ) -> String? {
        guard budget > 0, depth <= 6 else { return nil }
        budget -= 1

        if let value = copyStringAttribute(element, kAXValueAttribute as CFString),
           value.contains(expected) {
            return ""
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else {
            return nil
        }

        for (index, child) in list.enumerated() {
            if let path = search(expected, in: child, depth: depth + 1, budget: &budget) {
                let step = "filho[\(index)]"
                return path.isEmpty ? step : "\(step) → \(path)"
            }
        }
        return nil
    }

    /// Lê um atributo que devolve outro elemento da árvore.
    private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Lista todos os atributos do campo e diz quais contêm a ditagem.
    ///
    /// Diagnóstico para um problema específico: o `AXValue` do Cursor às vezes
    /// fica preso no placeholder mesmo com o texto visível na tela, e por isso
    /// não serve para decidir se a inserção falhou. Este dump responde se algum
    /// outro atributo — contagem de caracteres, posição do cursor, um filho da
    /// árvore — reflete o conteúdo real. Sem isso, qualquer regra nova seria
    /// chute com amostra pequena, que é como as anteriores falharam.
    private func dumpTextAttributes(of target: FocusedElement, expected: String) {
        let live = try? accessibilityService.focusedElement()
        let element = (live?.processID == target.processID ? live?.axElement : nil) ?? target.axElement

        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let attributes = names as? [String] else {
            logger.error("Dump AX: não foi possível listar os atributos.")
            return
        }

        logger.notice("Dump AX — \(attributes.count, privacy: .public) atributos: \(attributes.joined(separator: ", "), privacy: .public)")

        // Só o formato de cada valor, nunca o conteúdo: a ditagem é do usuário.
        for name in attributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let value else { continue }

            let description: String
            if let text = value as? String {
                description = "String(\(text.count) chars)\(text.contains(expected) ? " ← CONTÉM A DITAGEM" : "")"
            } else if let number = value as? NSNumber {
                description = "Number(\(number))"
            } else if let array = value as? [Any] {
                description = "Array(\(array.count) itens)"
            } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                description = "AXUIElement"
            } else {
                description = String(describing: CFCopyTypeIDDescription(CFGetTypeID(value)) as String? ?? "?")
            }
            logger.notice("Dump AX  \(name, privacy: .public) = \(description, privacy: .public)")
        }
    }

    /// `true` se alguma tecla foi pressionada depois de `reference`.
    ///
    /// O ⌘V que nós mesmos injetamos também conta como tecla, por isso a
    /// comparação é contra o instante em que ele saiu, com uma folga para o
    /// arredondamento do relógio de eventos.
    private func userTypedSince(_ reference: DispatchTime) -> Bool {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - reference.uptimeNanoseconds) / 1_000_000_000
        let sinceLastKey = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .keyDown
        )
        return sinceLastKey < elapsed - 0.05
    }

    /// Cursor, VS Code, Chrome e afins: valor AX do contenteditable é pouco confiável.
    private func isChromiumLike(_ target: FocusedElement) -> Bool {
        if let bundle = NSRunningApplication(processIdentifier: target.processID)?
            .bundleIdentifier?
            .lowercased() {
            let markers = [
                "cursor", "todesktop", "electron", "chrome", "chromium", "brave",
                "com.microsoft.vscode", "visualstudiocode", "slack", "discord", "figma"
            ]
            if markers.contains(where: { bundle.contains($0) }) {
                return true
            }
        }
        if target.role == "AXWebArea" {
            return true
        }
        return false
    }

    private func logDiagnostics(target: FocusedElement, captured: FocusedElement?, live: FocusedElement?) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "desconhecido"
        logger.notice(
            """
            Alvo: \(target.summary, privacy: .public) pid=\(target.processID, privacy: .public) \
            editável=\(self.isEditable(target), privacy: .public) \
            frontmost=\(frontmost, privacy: .public) \
            capturado=\(captured?.summary ?? "nenhum", privacy: .public) \
            ao-vivo=\(live?.summary ?? "nenhum", privacy: .public)
            """
        )
    }

    /// Alvo aceitável para escrita AX: papel de texto conhecido ou atributo gravável.
    private func isEditable(_ target: FocusedElement) -> Bool {
        if let role = target.role, editableRoles.contains(role) {
            return true
        }
        return isAttributeSettable(target.axElement, kAXSelectedTextAttribute as CFString)
            || isAttributeSettable(target.axElement, kAXValueAttribute as CFString)
    }

    /// Se o elemento (ou um descendente focado) for editável, devolve esse alvo.
    private func resolveEditableTarget(from target: FocusedElement) -> FocusedElement? {
        if isEditable(target) {
            return target
        }

        // Electron: o foco sobe para janela/grupo; desce de novo até o UI focado.
        guard let nested = focusedDescendant(of: target.axElement) else { return nil }

        let refined = FocusedElement(
            axElement: nested,
            processID: target.processID,
            applicationName: target.applicationName,
            role: copyStringAttribute(nested, kAXRoleAttribute as CFString)
        )
        guard isEditable(refined) else { return nil }

        logger.notice("Foco refinado: \(refined.summary, privacy: .public)")
        return refined
    }

    private func focusedDescendant(of element: AXUIElement) -> AXUIElement? {
        let containerRoles: Set<String> = [
            kAXApplicationRole as String,
            kAXWindowRole as String,
            "AXGroup",
            "AXWebArea",
            "AXScrollArea"
        ]

        var current = element
        for _ in 0..<5 {
            let role = copyStringAttribute(current, kAXRoleAttribute as CFString)
            guard let role, containerRoles.contains(role) else { return current }

            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                current,
                kAXFocusedUIElementAttribute as CFString,
                &value
            )
            guard status == .success,
                  let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            current = (value as! AXUIElement)
        }
        return current
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    // MARK: - Descoberta do alvo

    /// Procura o foco atual, insistindo até achar um campo realmente editável.
    ///
    /// O Chromium leva alguns instantes para montar a árvore de acessibilidade
    /// depois que ela é solicitada; desistir na primeira resposta devolveria só
    /// a janela, perdendo o campo de texto.
    /// Espera crescente: o caso comum (campo já pronto) acerta na primeira
    /// tentativa e não paga nada. Os degraus curtos no início recuperam rápido
    /// quando o Chromium ainda está montando a árvore, sem desistir cedo.
    private static let targetRetryDelaysMs = [15, 30, 50, 80, 120, 160, 200]

    private func resolveTargetWithRetry() async -> FocusedElement? {
        var lastSeen: FocusedElement?

        for attempt in 0...Self.targetRetryDelaysMs.count {
            if let target = try? accessibilityService.focusedElement(),
               target.processID != ownPID {
                if resolveEditableTarget(from: target) != nil {
                    return target
                }
                lastSeen = target
            }
            if attempt < Self.targetRetryDelaysMs.count {
                try? await Task.sleep(for: .milliseconds(Self.targetRetryDelaysMs[attempt]))
            }
        }
        return lastSeen
    }

    /// Só espera se houver modificador realmente preso.
    ///
    /// A versão anterior dormia 50 ms mesmo com o teclado limpo — que é o caso
    /// de toda ditagem encerrada por toggle, e o custo aparecia em cheio na
    /// latência percebida.
    private func waitForClearModifiers() async {
        let blocking: CGEventFlags = [.maskShift, .maskCommand, .maskAlternate, .maskControl]
        guard !CGEventSource.flagsState(.hidSystemState).intersection(blocking).isEmpty else {
            return
        }

        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(40))
            if CGEventSource.flagsState(.hidSystemState).intersection(blocking).isEmpty {
                // Settle curto: o app alvo ainda vai processar o flagsChanged
                // do release antes de receber o ⌘V.
                try? await Task.sleep(for: .milliseconds(50))
                return
            }
        }
        logger.warning("Modificadores ainda pressionados; seguindo mesmo assim.")
    }

    // MARK: - Accessibility verificado

    private func insertViaAccessibilityVerified(_ text: String, into target: FocusedElement) -> Bool {
        let role = target.role ?? ""
        guard editableRoles.contains(role) else {
            logger.info("Papel \(role.isEmpty ? "desconhecido" : role, privacy: .public) não é campo editável nativo.")
            return false
        }

        let element = target.axElement
        let placeholder = axPlaceholder(of: element)
        let beforeRaw = copyStringAttribute(element, kAXValueAttribute as CFString)
        let before = strippingPlaceholder(from: beforeRaw, placeholder: placeholder)

        // Só selectedText. Reescrever kAXValueAttribute no Electron materializa o
        // placeholder ("Send follow-up") como texto real no contenteditable.
        if setAttribute(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef),
           didInsertSucceed(
            element,
            beforeRaw: beforeRaw,
            before: before,
            inserted: text,
            placeholder: placeholder
           ) {
            return true
        }

        return false
    }

    /// Placeholder AX (nativo) ou valor que o Electron expõe como se fosse conteúdo.
    private func axPlaceholder(of element: AXUIElement) -> String? {
        if let placeholder = copyStringAttribute(element, kAXPlaceholderValueAttribute as CFString),
           !placeholder.isEmpty {
            return placeholder
        }
        return nil
    }

    private func strippingPlaceholder(from raw: String?, placeholder: String?) -> String {
        guard var value = raw, !value.isEmpty else { return "" }
        guard let placeholder, !placeholder.isEmpty else { return value }

        if value == placeholder {
            return ""
        }
        // Cursor/Electron: muitas vezes o valor AX é "conteúdo real" + placeholder no fim.
        if value.hasSuffix(placeholder) {
            value.removeLast(placeholder.count)
            return value
        }
        if value.hasPrefix(placeholder) {
            value.removeFirst(placeholder.count)
            return value
        }
        return value
    }

    /// Confirma inserção real e rejeita se o placeholder do Electron ficou no valor.
    private func didInsertSucceed(
        _ element: AXUIElement,
        beforeRaw: String?,
        before: String,
        inserted: String,
        placeholder: String?
    ) -> Bool {
        let afterRaw = copyStringAttribute(element, kAXValueAttribute as CFString)
        let after = strippingPlaceholder(from: afterRaw, placeholder: placeholder)

        guard let afterRaw, after.contains(inserted), after != before else { return false }

        // Placeholder oficial ainda presente no valor cru.
        if let placeholder,
           !inserted.contains(placeholder),
           afterRaw.contains(placeholder) {
            logger.info("AX manteve o placeholder \"\(placeholder, privacy: .public)\"; tratando como falha.")
            return false
        }

        // Sem atributo placeholder: valor curto anterior preservado no after
        // (ex.: "Send follow-up") → era placeholder do Electron.
        if let beforeRaw,
           !beforeRaw.isEmpty,
           beforeRaw.count <= 48,
           !beforeRaw.contains("\n"),
           !inserted.contains(beforeRaw),
           afterRaw.contains(beforeRaw),
           afterRaw != inserted {
            logger.info("AX preservou rótulo curto pré-existente; tratando como placeholder.")
            return false
        }

        return true
    }

    // MARK: - Digitação Unicode (sem clipboard)

    /// Envia o texto como eventos de teclado com payload Unicode.
    ///
    /// `keyboardSetUnicodeString` entrega os caracteres direto ao cliente de
    /// entrada de texto do app (inclusive Chromium), sem depender de layout de
    /// teclado nem da área de transferência. `virtualKey: 0` evita que o app
    /// interprete o evento como atalho — inclusive `\n`, que entra como quebra
    /// de linha em vez de disparar o Enter.
    /// - Returns: `true` se todos os eventos foram enviados. Como na colagem,
    ///   não afirma que o texto apareceu — só que a entrega saiu daqui.
    private func insertViaUnicodeTyping(_ text: String, target: FocusedElement) async -> Bool {
        try? await activateAndWait(pid: target.processID)

        // `privateState` isola o estado de modificadores do teclado físico:
        // sem isso, um Shift residual do ⇧ Tab contamina a digitação.
        guard let source = CGEventSource(stateID: .privateState) else {
            logger.error("Não foi possível criar a fonte de eventos para digitar.")
            return false
        }
        source.keyboardType = 0

        for chunk in unicodeChunks(of: text) {
            guard postUnicodeChunk(chunk, source: source) else {
                logger.error("Falha ao criar evento de digitação Unicode.")
                return false
            }
        }

        logger.notice("Digitação Unicode enviada (\(text.count, privacy: .public) chars).")
        return true
    }

    /// Quebra o texto em blocos curtos: eventos com payload longo demais são
    /// truncados por alguns apps. O corte respeita `Character` para não
    /// separar emoji nem acentos compostos.
    private func unicodeChunks(of text: String, maxUnits: Int = 16) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0

        for character in text {
            let units = character.utf16.count
            if currentUnits + units > maxUnits, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func postUnicodeChunk(_ chunk: String, source: CGEventSource) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        let units = Array(chunk.utf16)
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }

        keyDown.flags = []
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        usleep(1_800)
        keyUp.post(tap: .cghidEventTap)
        usleep(1_800)
        return true
    }

    // MARK: - Clipboard + ⌘V (caminho principal)

    /// Cola via ⌘V e **sempre** devolve o clipboard original ao usuário.
    ///
    /// Nunca deixamos a ditagem na área de transferência sem que o usuário peça:
    /// substituir o que ele havia copiado é perda de dado do ponto de vista dele.
    ///
    /// - Returns: `true` se algum mecanismo de entrega aceitou o evento. Não diz
    ///   que o texto apareceu no campo — essa pergunta o AX não responde de
    ///   forma confiável em Electron, e tentar respondê-la foi a origem da
    ///   perda silenciosa, da barra de resgate falsa e da duplicação.
    private func insertViaClipboardPaste(_ text: String, target: FocusedElement) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        // A marca vem antes do texto: um gerenciador que leia o clipboard entre
        // as duas escritas veria a ditagem sem saber que é de passagem.
        pasteboard.setData(Data(), forType: .transient)
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(into: pasteboard)
            return false
        }

        // O `changeCount` é o contador global do pasteboard: ele sobe a cada
        // escrita, de qualquer processo. Se subir entre a nossa escrita e o
        // ⌘V, alguém mexeu no clipboard no meio — e o app alvo vai colar outra
        // coisa. É a única hipótese que sobrou para a ditagem sumir sem
        // aparecer em lugar nenhum.
        let ourChangeCount = pasteboard.changeCount
        logger.notice(
            """
            Clipboard escrito: changeCount \(ourChangeCount, privacy: .public), \
            relido \(pasteboard.string(forType: .string)?.count ?? -1, privacy: .public) de \
            \(text.count, privacy: .public) chars.
            """
        )

        let pasteStart = DispatchTime.now()
        func elapsedMs() -> Int {
            Int(Double(DispatchTime.now().uptimeNanoseconds - pasteStart.uptimeNanoseconds) / 1_000_000)
        }

        /// Confere se o clipboard ainda é o nosso, e loga quem o alterou.
        func checkClipboard(_ momento: String) {
            let now = pasteboard.changeCount
            let readBack = pasteboard.string(forType: .string)?.count ?? -1
            if now != ourChangeCount || readBack != text.count {
                logger.error(
                    """
                    Clipboard ALTERADO \(momento, privacy: .public) (+\(elapsedMs(), privacy: .public) ms): \
                    changeCount \(ourChangeCount, privacy: .public) → \(now, privacy: .public), \
                    conteúdo \(readBack, privacy: .public) chars (esperado \(text.count, privacy: .public)).
                    """
                )
            } else {
                logger.notice(
                    "Clipboard intacto \(momento, privacy: .public) (+\(elapsedMs(), privacy: .public) ms)."
                )
            }
        }

        // O momento da devolução importa: se o app alvo ainda não tiver lido o
        // clipboard, ele passa a ler o conteúdo antigo e a ditagem se perde.
        defer {
            snapshot.restore(into: pasteboard)
            logger.notice("Clipboard devolvido ao usuário em +\(elapsedMs(), privacy: .public) ms.")
        }

        try? await activateAndWait(pid: target.processID)
        checkClipboard("antes do ⌘V")

        // Modificador físico ainda pressionado transforma o ⌘V em outro atalho
        // (⇧⌘V, ⌥⌘V), que o app pode simplesmente ignorar — o que explicaria a
        // ditagem sumir sem colar em lugar nenhum. O atalho de ditado é ⇧Tab,
        // então o Shift é o suspeito natural.
        let flags = CGEventSource.flagsState(.hidSystemState)
        let presos = [
            (CGEventFlags.maskShift, "⇧"), (.maskCommand, "⌘"),
            (.maskAlternate, "⌥"), (.maskControl, "⌃"), (.maskSecondaryFn, "fn")
        ].filter { flags.contains($0.0) }.map(\.1).joined()
        if !presos.isEmpty {
            logger.error("Modificadores AINDA pressionados no envio do ⌘V: \(presos, privacy: .public)")
        }

        // Frontmost real no instante do envio: se não for o alvo, o evento vai
        // para outra janela.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != target.processID {
            logger.error(
                """
                Frontmost mudou antes do ⌘V: \(front?.bundleIdentifier ?? "?", privacy: .public) \
                (esperado pid \(target.processID, privacy: .public)).
                """
            )
        }

        if postPasteShortcut(tap: .cghidEventTap) {
            lastMethod = .clipboardHID
        } else if postPasteShortcut(tap: .cgSessionEventTap) {
            lastMethod = .clipboardSession
        } else if pasteViaSystemEvents() {
            lastMethod = .clipboardSystemEvents
        } else {
            return false
        }

        logger.notice(
            """
            ⌘V enviado em +\(elapsedMs(), privacy: .public) ms via \
            \(self.lastMethod?.rawValue ?? "—", privacy: .public) — \
            \(text.count, privacy: .public) chars.
            """
        )

        // Tempo para o app consumir o ⌘V antes de o `defer` devolver o
        // clipboard. Devolver cedo demais faz o app colar o conteúdo anterior.
        // Como a ditagem vai marcada como transitória, segurá-la um pouco mais
        // não suja o histórico de clipboard — e nada disso é latência
        // percebida: o texto já apareceu bem antes.
        // Meio do settle: se o clipboard mudar aqui, mudou enquanto o app ainda
        // tinha o ⌘V para processar.
        try? await Task.sleep(for: .milliseconds(Self.pasteSettleMs / 2))
        checkClipboard("no meio do settle")

        try? await Task.sleep(for: .milliseconds(Self.pasteSettleMs / 2))
        checkClipboard("ao fim do settle")
        return true
    }

    /// Quanto tempo a ditagem fica no clipboard depois do ⌘V.
    private static let pasteSettleMs = 900

    /// Ativa o app alvo e aguarda ele virar frontmost de fato.
    private func activateAndWait(pid: pid_t) async throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw VoiceInputError.textInsertionFailed
        }
        app.activate()

        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        logger.warning("App alvo não ficou frontmost; seguindo mesmo assim.")
    }

    /// Envia ⌘V como sequência completa de eventos.
    ///
    /// O Chromium (Electron) reconstrói o estado dos modificadores a partir dos
    /// eventos `flagsChanged`; enviar só key down/up com `flags` definido faz o
    /// Cursor ignorar o atalho.
    private func postPasteShortcut(tap: CGEventTapLocation) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }

        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)

        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false) else {
            return false
        }

        commandDown.type = .flagsChanged
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.type = .flagsChanged
        commandUp.flags = []

        // Pausa entre os eventos: o Chromium reconstrói o estado dos
        // modificadores a partir dos `flagsChanged`, que atravessam IPC entre
        // processos. Se o `keyDown` do V chegar antes de o ⌘ ter sido
        // processado, a sequência é descartada — nada cola, e nem sequer entra
        // um "v" solto.
        //
        // Este valor já foi 18 ms e eu o reduzi para 8 ms no PR de latência
        // (#4), para economizar 40 ms, chamando 8 ms de "o menor valor que o
        // Chromium ainda processa de forma confiável" — o que era estimativa,
        // não medição. Voltou para 18 ms: perder a ditagem custa muito mais que
        // 40 ms, e esses 40 ms não são latência percebida de qualquer forma.
        for event in [commandDown, vDown, vUp, commandUp] {
            event.post(tap: tap)
            usleep(18_000)
        }
        return true
    }

    /// Último recurso quando a injeção via CGEvent não é aceita.
    private func pasteViaSystemEvents() -> Bool {
        let script = """
        tell application "System Events" to keystroke "v" using {command down}
        """
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return false }
        _ = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            logger.error("System Events falhou: \(String(describing: errorInfo), privacy: .public)")
            return false
        }
        return true
    }

    // MARK: - AX helpers

    private func setAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return value as? String
    }
}
