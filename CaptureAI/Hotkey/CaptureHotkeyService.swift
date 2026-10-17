import Carbon
import Foundation

/// Monitoramento global do atalho de captura de tela.
///
/// Só reage ao pressionar — captura é um toque, não um segurar. Usa uma
/// assinatura de `EventHotKeyID` própria, e o handler confere essa assinatura
/// antes de disparar: o handler Carbon é instalado no dispatcher global e
/// recebe os eventos de **todos** os atalhos registrados pelo app, não apenas
/// os seus.
nonisolated final class CaptureHotkeyService: @unchecked Sendable {
    /// Chamado quando o atalho é pressionado.
    var onTriggered: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var keyCode: UInt32 = CaptureHotkey.default.keyCode
    private var modifiers: UInt32 = CaptureHotkey.default.modifiers

    private let hotKeyID = EventHotKeyID(
        signature: FourCharCode(fromString: "CAP1"),
        id: 2
    )

    func start(keyCode: UInt32, modifiers: UInt32) {
        stop()
        self.keyCode = keyCode
        self.modifiers = modifiers
        installHandler()
        registerHotKey()
    }

    func stop() {
        unregisterHotKeyOnly()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    func rebind(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        unregisterHotKeyOnly()
        if handlerRef == nil { installHandler() }
        registerHotKey()
    }

    deinit { stop() }

    // MARK: - Privado

    private func unregisterHotKeyOnly() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func registerHotKey() {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        // Sem assertion: ao contrário do ditado, este atalho pode legitimamente
        // falhar por já pertencer a outro app, e isso não é motivo para
        // derrubar o app em debug. A UI mostra o estado.
        guard status == noErr else { return }
        hotKeyRef = ref
    }

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var handler: EventHandlerRef?

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }

                var firedID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                guard readStatus == noErr else { return noErr }

                let service = Unmanaged<CaptureHotkeyService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                // O atalho de ditado passa por aqui também; ignoramos o que não é nosso.
                guard firedID.signature == service.hotKeyID.signature,
                      firedID.id == service.hotKeyID.id else { return noErr }

                service.onTriggered?()
                return noErr
            },
            1,
            &eventTypes,
            userData,
            &handler
        )

        guard status == noErr else { return }
        handlerRef = handler
    }
}

extension FourCharCode {
    /// Converte quatro caracteres ASCII no código que o Carbon espera.
    init(fromString string: String) {
        precondition(string.utf8.count == 4)
        var result: FourCharCode = 0
        for byte in string.utf8 {
            result = (result << 8) + FourCharCode(byte)
        }
        self = result
    }
}
