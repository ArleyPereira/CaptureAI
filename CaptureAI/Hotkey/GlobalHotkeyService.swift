import Carbon
import Foundation

/// Monitoramento global do atalho de ditado (push-to-talk).
nonisolated final class GlobalHotkeyService: GlobalHotkeyServiceProtocol, @unchecked Sendable {
    /// Chamado quando o atalho é pressionado.
    var onPressed: (@Sendable () -> Void)?

    /// Chamado quando o atalho é solto.
    var onReleased: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isHotkeyHeld = false
    private let lock = NSLock()
    private var keyCode: UInt32 = DictationHotkey.default.keyCode
    private var modifiers: UInt32 = DictationHotkey.default.modifiers

    private let hotKeyID = EventHotKeyID(
        signature: FourCharCode(fromString: "VIA1"),
        id: 1
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

        resetHoldState()
    }

    func rebind(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        unregisterHotKeyOnly()
        resetHoldState()
        if handlerRef == nil {
            installHandler()
        }
        registerHotKey()
    }

    func resetHoldState() {
        lock.lock()
        isHotkeyHeld = false
        lock.unlock()
    }

    func forceHeld() {
        lock.lock()
        isHotkeyHeld = true
        lock.unlock()
    }

    deinit {
        stop()
    }

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

        guard status == noErr else {
            assertionFailure("Falha ao registrar atalho global: \(status)")
            return
        }

        hotKeyRef = ref
    }

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var handler: EventHandlerRef?

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                // `noErr` significa "já tratei este evento" e interrompe a
                // cadeia. Tudo que não for nosso precisa devolver
                // `eventNotHandledErr`, ou o outro handler do app nunca é
                // chamado — foi assim que a captura passou a engolir o ditado.
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                let service = Unmanaged<GlobalHotkeyService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                // O handler fica no dispatcher global e recebe os eventos de
                // todos os atalhos do app — inclusive o da captura de tela.
                // Sem conferir a identidade, apertar Print Screen começaria uma
                // gravação.
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
                guard readStatus == noErr,
                      firedID.signature == service.hotKeyID.signature,
                      firedID.id == service.hotKeyID.id else {
                    return OSStatus(eventNotHandledErr)
                }

                let kind = GetEventKind(event)
                if kind == UInt32(kEventHotKeyPressed) {
                    service.handlePressed()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    service.handleReleased()
                }

                return noErr
            },
            2,
            &eventTypes,
            userData,
            &handler
        )

        guard status == noErr else {
            assertionFailure("Falha ao instalar handler do atalho: \(status)")
            return
        }

        handlerRef = handler
    }

    private func handlePressed() {
        lock.lock()
        let alreadyHeld = isHotkeyHeld
        if !alreadyHeld {
            isHotkeyHeld = true
        }
        lock.unlock()

        guard !alreadyHeld else { return }
        onPressed?()
    }

    private func handleReleased() {
        lock.lock()
        let wasHeld = isHotkeyHeld
        isHotkeyHeld = false
        lock.unlock()

        guard wasHeld else { return }
        onReleased?()
    }
}

