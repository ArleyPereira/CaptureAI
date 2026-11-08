import AppKit
import ApplicationServices

/// Acha a modal sob o mouse dentro de uma janela.
///
/// Uma modal de página (a de um card no Xquad, por exemplo) não é uma janela
/// do macOS: o site a desenha dentro da página, e para o sistema só existe a
/// janela do navegador. Mas navegadores e apps Electron publicam a página na
/// árvore de acessibilidade, e ali a modal aparece como diálogo
/// (`AXApplicationDialog`), com posição e tamanho próprios. É isso que se
/// procura no ponto do mouse.
///
/// Uma "modal" desenhada sem essa marcação não é encontrada, e o alvo
/// continua sendo a janela inteira.
@MainActor
enum ModalDetector {
    private nonisolated static let dialogSubroles: Set<String> = ["AXApplicationDialog", "AXDialog", "AXSystemDialog"]
    private nonisolated static let dialogRoles: Set<String> = ["AXSheet"]

    /// Apps em que o `AXEnhancedUserInterface` foi ligado pelo CaptureAI.
    private static var enhancedPIDs: Set<pid_t> = []
    private static var activationObserver: NSObjectProtocol?

    /// Mantém a árvore da página pronta no app em primeiro plano.
    ///
    /// O Chrome só publica o conteúdo da página com o
    /// `AXEnhancedUserInterface` ligado, leva uns 2 s para montar a árvore e
    /// — o ponto que importa — não monta enquanto está coberto. O editor de
    /// captura cobre a tela toda, então ligar no Print Screen é tarde demais:
    /// a modal só aparecia da segunda captura em diante. Por isso o atributo
    /// é ligado quando o app vem para a frente, só nele, e desligado no app
    /// que saiu da frente.
    static func startFollowingFrontmostApp() {
        guard activationObserver == nil else { return }
        if let app = NSWorkspace.shared.frontmostApplication {
            focus(on: app.processIdentifier)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { focus(on: pid) }
        }
    }

    private static func focus(on pid: pid_t) {
        // O próprio CaptureAI vem para a frente ao abrir o editor: aí o app
        // que estava na frente continua sendo o alvo.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        for other in enhancedPIDs where other != pid {
            setEnhanced(false, pid: other)
        }
        enhancedPIDs = enhancedPIDs.filter { $0 == pid }
        enable(pid)
    }

    /// Pedido de última hora para as janelas na tela, no aperto do atalho.
    /// Serve para apps que já estavam com a árvore montada; os demais são
    /// cobertos por `startFollowingFrontmostApp`.
    static func prepare(_ windows: [CapturableWindow]) {
        let own = ProcessInfo.processInfo.processIdentifier
        for pid in Set(windows.map(\.ownerPID)) where pid > 0 && pid != own {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            // Electron (Slack, Teams) publica a página com este atributo.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    private static func enable(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Só liga onde estava desligado, para devolver como encontrou: um
        // leitor de tela que já o tinha ligado continua com ele ligado.
        guard !enhancedPIDs.contains(pid), !isEnhanced(app) else { return }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        enhancedPIDs.insert(pid)
    }

    private static func setEnhanced(_ on: Bool, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Desliga tudo o que foi ligado — ao sair do app.
    static func restore() {
        for pid in enhancedPIDs { setEnhanced(false, pid: pid) }
        enhancedPIDs.removeAll()
    }

    private static func isEnhanced(_ app: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Uma busca por vez, fora da thread principal: enquanto o navegador
    /// monta a árvore da página cada pergunta pode esperar o tempo-limite, e
    /// isso não pode congelar o editor.
    private static let queue = DispatchQueue(label: "dev.arley.santana.CaptureAI.modal", qos: .userInteractive)

    /// Procura a modal no ponto e responde na thread principal.
    nonisolated static func findDialog(
        at point: CGPoint,
        in window: CapturableWindow,
        completion: @escaping @MainActor (CGRect?) -> Void
    ) {
        queue.async {
            let frame = dialogFrame(at: point, in: window)
            DispatchQueue.main.async { completion(frame) }
        }
    }

    /// O retângulo da modal no ponto, em coordenadas globais com origem no
    /// topo do monitor principal — as mesmas do `CGWindowList`.
    nonisolated static func dialogFrame(at point: CGPoint, in window: CapturableWindow) -> CGRect? {
        // A própria janela de configurações do CaptureAI responde pelo laço
        // principal: perguntar a si mesmo só esperaria o tempo-limite.
        guard window.ownerPID > 0, window.ownerPID != ProcessInfo.processInfo.processIdentifier else { return nil }

        let app = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }

        var current = hit
        for _ in 0..<40 {
            guard let element = current else { break }
            // Um tempo-limite aqui é o app ocupado: desiste da busca inteira
            // em vez de esperar de novo em cada nível.
            guard let role = string(element, kAXRoleAttribute) else { return nil }
            if role == kAXWindowRole as String { break }
            let subrole = string(element, kAXSubroleAttribute) ?? ""
            if dialogSubroles.contains(subrole) || dialogRoles.contains(role) {
                if let frame = frame(of: element), isPlausible(frame, in: window.frame) {
                    return frame
                }
            }
            current = parent(of: element)
        }
        return nil
    }

    /// Uma modal de verdade é menor que a janela e está dentro dela; um
    /// diálogo do tamanho da janela toda não acrescenta nada à captura dela.
    private nonisolated static func isPlausible(_ frame: CGRect, in windowFrame: CGRect) -> Bool {
        guard frame.width >= 80, frame.height >= 60 else { return false }
        let inside = frame.intersection(windowFrame)
        guard inside.width * inside.height >= frame.width * frame.height * 0.9 else { return false }
        return frame.width < windowFrame.width - 8 || frame.height < windowFrame.height - 8
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private nonisolated static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?
        var size: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
            let position, let size,
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
