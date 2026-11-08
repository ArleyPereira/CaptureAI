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
    private static let dialogSubroles: Set<String> = ["AXApplicationDialog", "AXDialog", "AXSystemDialog"]
    private static let dialogRoles: Set<String> = ["AXSheet"]

    /// Pede aos apps que montem a árvore de acessibilidade das páginas.
    ///
    /// O Chrome monta sozinho quando percebe um cliente de acessibilidade;
    /// apps Electron (Slack, Teams) só com o `AXManualAccessibility`.
    static func prepare(_ windows: [CapturableWindow]) {
        let own = ProcessInfo.processInfo.processIdentifier
        for pid in Set(windows.map(\.ownerPID)) where pid > 0 && pid != own {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// O retângulo da modal no ponto, em coordenadas globais com origem no
    /// topo do monitor principal — as mesmas do `CGWindowList`.
    static func dialogFrame(at point: CGPoint, in window: CapturableWindow) -> CGRect? {
        // A própria janela de configurações do CaptureAI responde pelo laço
        // principal, que é este: perguntar a si mesmo travaria até o tempo-limite.
        guard window.ownerPID > 0, window.ownerPID != ProcessInfo.processInfo.processIdentifier else { return nil }

        let app = AXUIElementCreateApplication(window.ownerPID)
        // Um app ocupado não pode segurar o editor: sem resposta rápida, fica
        // a janela inteira.
        AXUIElementSetMessagingTimeout(app, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }

        var current = hit
        for _ in 0..<40 {
            guard let element = current else { break }
            let role = string(element, kAXRoleAttribute)
            if role == kAXWindowRole as String { break }
            let subrole = string(element, kAXSubroleAttribute) ?? ""
            if dialogSubroles.contains(subrole) || dialogRoles.contains(role ?? "") {
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
    private static func isPlausible(_ frame: CGRect, in windowFrame: CGRect) -> Bool {
        guard frame.width >= 80, frame.height >= 60 else { return false }
        let inside = frame.intersection(windowFrame)
        guard inside.width * inside.height >= frame.width * frame.height * 0.9 else { return false }
        return frame.width < windowFrame.width - 8 || frame.height < windowFrame.height - 8
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
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
