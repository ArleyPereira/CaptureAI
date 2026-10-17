import Carbon
import Foundation

/// Monitoramento global do atalho de captura de tela.
///
/// O atalho principal abre a captura de área. Enquanto ele está **segurado**,
/// o W também vira atalho e troca para captura de janela — é o acorde
/// Print Screen + W. O macOS não registra acorde de duas teclas comuns, então
/// o W é registrado ao pressionar e removido ao soltar: fora desse instante
/// ele volta a digitar W normalmente em qualquer app.
///
/// O handler Carbon fica no dispatcher global e recebe os eventos de todos os
/// atalhos do app, por isso confere a identidade de cada um e devolve
/// `eventNotHandledErr` para o que não é seu — devolver `noErr` encerraria a
/// cadeia e o atalho de ditado deixaria de funcionar.
nonisolated final class CaptureHotkeyService: @unchecked Sendable {
    /// Chamado quando o atalho principal é pressionado.
    var onTriggered: (@Sendable () -> Void)?
    /// Chamado quando W é pressionado com o atalho principal segurado.
    var onWindowModeRequested: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var modeKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var keyCode: UInt32 = CaptureHotkey.default.keyCode
    private var modifiers: UInt32 = CaptureHotkey.default.modifiers
    private let lock = NSLock()

    private static let signature = FourCharCode(fromString: "CAP1")
    private let mainID = EventHotKeyID(signature: CaptureHotkeyService.signature, id: 2)
    private let modeKeyID = EventHotKeyID(signature: CaptureHotkeyService.signature, id: 3)

    func start(keyCode: UInt32, modifiers: UInt32) {
        stop()
        self.keyCode = keyCode
        self.modifiers = modifiers
        installHandler()
        registerMainHotKey()
    }

    func stop() {
        unregisterModeKey()
        unregisterMainHotKey()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    func rebind(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        unregisterModeKey()
        unregisterMainHotKey()
        if handlerRef == nil { installHandler() }
        registerMainHotKey()
    }

    deinit { stop() }

    // MARK: - Registro

    private func registerMainHotKey() {
        var ref: EventHotKeyRef?
        // Sem assertion: este atalho pode legitimamente já pertencer a outro
        // app, e isso não é motivo para derrubar o app em debug.
        guard RegisterEventHotKey(keyCode, modifiers, mainID, GetEventDispatcherTarget(), 0, &ref) == noErr else {
            return
        }
        hotKeyRef = ref
    }

    private func unregisterMainHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// W vira atalho só enquanto o principal está segurado.
    private func registerModeKey() {
        lock.lock()
        defer { lock.unlock() }
        guard modeKeyRef == nil else { return }
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(UInt32(kVK_ANSI_W), 0, modeKeyID, GetEventDispatcherTarget(), 0, &ref) == noErr {
            modeKeyRef = ref
        }
    }

    private func unregisterModeKey() {
        lock.lock()
        defer { lock.unlock() }
        if let modeKeyRef {
            UnregisterEventHotKey(modeKeyRef)
            self.modeKeyRef = nil
        }
    }

    // MARK: - Eventos

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var handler: EventHandlerRef?

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var firedID = EventHotKeyID()
                guard GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                ) == noErr, firedID.signature == CaptureHotkeyService.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                let service = Unmanaged<CaptureHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                return service.handle(id: firedID.id, pressed: pressed)
            },
            eventTypes.count,
            &eventTypes,
            userData,
            &handler
        )

        guard status == noErr else { return }
        handlerRef = handler
    }

    private func handle(id: UInt32, pressed: Bool) -> OSStatus {
        switch (id, pressed) {
        case (mainID.id, true):
            registerModeKey()
            onTriggered?()
        case (mainID.id, false):
            unregisterModeKey()
        case (modeKeyID.id, true):
            onWindowModeRequested?()
        case (modeKeyID.id, false):
            break
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
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
