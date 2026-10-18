import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Descobre o aplicativo e o elemento de UI focados via Accessibility API.
///
/// Apps Electron/Chromium (Cursor, VS Code, Chrome) nem sempre publicam
/// `kAXFocusedUIElement` no elemento system-wide. Por isso a busca é feita em
/// cascata e ainda desce pela árvore (aplicativo → janela → elemento focado).
final class AccessibilityService: AccessibilityServiceProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "accessibility")
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Quantos pedidos de árvore completa cada app já recebeu (evita repetir).
    private var manualAccessibilityStages: [pid_t: Int] = [:]
    private let manualAccessibilityLock = NSLock()

    func isTrusted() -> Bool {
        AccessibilityPermission.isTrusted
    }

    @discardableResult
    func requestAccess() -> Bool {
        AccessibilityPermission.requestAccess()
    }

    /// Teto para cada consulta AX, em segundos.
    ///
    /// O padrão do sistema é 6 s. Um Electron ocupado — logo depois de receber
    /// uma colagem grande, por exemplo — segura a resposta por muito tempo, e
    /// uma verificação que deveria custar milissegundos trava o ditado inteiro.
    /// Falhar rápido e reler é melhor do que esperar. (O Spokenly também define
    /// esse timeout.)
    private static let axMessagingTimeout: Float = 0.5

    func focusedElement() throws -> FocusedElement {
        guard isTrusted() else {
            throw VoiceInputError.accessibilityPermissionDenied
        }

        if let element = focusedUIElement(from: AXUIElementCreateSystemWide()) {
            return makeFocused(descend(element))
        }

        guard let appElement = focusedApplicationElement() ?? frontmostApplicationElement() else {
            logger.error("Nenhum aplicativo focado encontrado")
            throw VoiceInputError.noFocusedElement
        }

        // Chromium/Electron (Cursor, VS Code, Chrome) só monta a árvore de
        // acessibilidade quando detecta um cliente assistivo. Sem este pedido o
        // app não publica `kAXFocusedUIElement` e parece "sem foco".
        enableManualAccessibility(on: appElement)

        if let element = focusedUIElement(from: appElement) {
            return makeFocused(descend(element))
        }

        // Ainda sem elemento: a janela focada serve de alvo para digitação
        // sintética. Sem janela focada (Mesa/Finder) não há onde escrever.
        if let window = copyElementAttribute(appElement, kAXFocusedWindowAttribute as CFString) {
            logger.notice("Sem UI focada; usando a janela focada como alvo.")
            return makeFocused(descend(window))
        }

        logger.error("Nenhum elemento focado encontrado")
        throw VoiceInputError.noFocusedElement
    }

    /// Pede ao app que exponha a árvore de acessibilidade completa.
    ///
    /// Em dois estágios, porque montar a árvore é caro para o app alvo:
    /// 1. `AXManualAccessibility` — sinal específico do Chromium/Electron.
    /// 2. `AXEnhancedUserInterface` — o sinal clássico do VoiceOver, usado só
    ///    quando o primeiro não bastou (pode mexer no tamanho das janelas).
    private func enableManualAccessibility(on appElement: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(appElement, &pid)
        guard pid != 0, pid != ownPID else { return }

        manualAccessibilityLock.lock()
        let stage = manualAccessibilityStages[pid] ?? 0
        manualAccessibilityStages[pid] = stage + 1
        manualAccessibilityLock.unlock()

        let attribute: String
        switch stage {
        case 0:
            attribute = "AXManualAccessibility"
        case 1:
            attribute = "AXEnhancedUserInterface"
        default:
            return
        }

        let status = AXUIElementSetAttributeValue(
            appElement,
            attribute as CFString,
            kCFBooleanTrue
        )
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        logger.notice(
            "\(attribute, privacy: .public) solicitado a \(appName, privacy: .public) (status=\(status.rawValue, privacy: .public))."
        )
    }

    // MARK: - Resolução

    /// Desce de aplicativo/janela até o elemento realmente focado.
    private func descend(_ element: AXUIElement) -> AXUIElement {
        var current = element

        for _ in 0..<4 {
            guard let role = copyStringAttribute(current, kAXRoleAttribute as CFString) else {
                return current
            }

            switch role {
            case kAXApplicationRole as String:
                if let focused = copyElementAttribute(current, kAXFocusedUIElementAttribute as CFString) {
                    current = focused
                } else if let window = copyElementAttribute(current, kAXFocusedWindowAttribute as CFString) {
                    current = window
                } else {
                    return current
                }
            case kAXWindowRole as String:
                guard let focused = copyElementAttribute(current, kAXFocusedUIElementAttribute as CFString) else {
                    return current
                }
                current = focused
            default:
                return current
            }
        }

        return current
    }

    private func focusedApplicationElement() -> AXUIElement? {
        guard let appElement = copyElementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as CFString
        ) else {
            return nil
        }

        var pid: pid_t = 0
        AXUIElementGetPid(appElement, &pid)
        guard pid != ownPID else { return nil }
        return appElement
    }

    private func frontmostApplicationElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func focusedUIElement(from container: AXUIElement) -> AXUIElement? {
        guard let element = copyElementAttribute(container, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ownPID else { return nil }
        return element
    }

    private func makeFocused(_ element: AXUIElement) -> FocusedElement {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        // Vale para todas as consultas futuras neste elemento, inclusive as da
        // verificação de inserção.
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)

        let focused = FocusedElement(
            axElement: element,
            processID: pid,
            applicationName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            role: copyStringAttribute(element, kAXRoleAttribute as CFString)
        )
        logger.notice("Foco capturado: \(focused.summary, privacy: .public)")
        return focused
    }

    // MARK: - Helpers

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return value as? String
    }
}
