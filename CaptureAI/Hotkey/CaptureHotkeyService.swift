import Carbon
import Foundation

/// Monitoramento global do atalho de captura de tela.
///
/// A captura de área começa ao **soltar** o atalho principal, não ao apertar:
/// enquanto ele está segurado a pessoa ainda pode estar no meio de um acorde,
/// e escurecer a tela antes da hora atropelaria a escolha. Com o principal
/// segurado, W abre a captura de janela e F a de tela inteira; aí o soltar não
/// faz mais nada. O macOS não registra acorde de duas teclas comuns, então W
/// e F só são interceptadas enquanto o principal está segurado: fora desse
/// instante voltam a digitar normalmente em qualquer app.
///
/// A interceptação é um *event tap* ativo, ligado ao pressionar e desligado ao
/// soltar. Atalho Carbon de letra sem modificador não dispara nas versões
/// atuais do macOS: o W ia parar no campo em foco e o editor abria no modo
/// área. O tap depende da permissão de Acessibilidade, que o ditado já exige;
/// sem ela, sobra o registro Carbon como tentativa.
///
/// O handler Carbon fica no dispatcher global e recebe os eventos de todos os
/// atalhos do app, por isso confere a identidade de cada um e devolve
/// `eventNotHandledErr` para o que não é seu — devolver `noErr` encerraria a
/// cadeia e o atalho de ditado deixaria de funcionar.
nonisolated final class CaptureHotkeyService: @unchecked Sendable {
    /// Captura de área: o atalho principal foi solto sem acorde.
    var onTriggered: (@Sendable () -> Void)?
    /// Captura de janela: W apertado com o atalho principal segurado.
    var onWindowModeRequested: (@Sendable () -> Void)?
    /// Tela inteira: F apertado com o atalho principal segurado.
    var onFullScreenRequested: (@Sendable () -> Void)?

    /// O atalho principal está pressionado agora.
    private var isMainHeld = false
    /// O acorde já disparou uma captura; o soltar não abre outra.
    private var chordConsumed = false

    private var hotKeyRef: EventHotKeyRef?
    private var modeKeyRefs: [EventHotKeyRef] = []
    private var modeKeyTap: CFMachPort?
    private var modeKeyTapSource: CFRunLoopSource?
    private var handlerRef: EventHandlerRef?
    private var keyCode: UInt32 = CaptureHotkey.default.keyCode
    private var modifiers: UInt32 = CaptureHotkey.default.modifiers
    private let lock = NSLock()

    private static let signature = FourCharCode(fromString: "CAP1")
    private let mainID = EventHotKeyID(signature: CaptureHotkeyService.signature, id: 2)
    private let windowKeyID = EventHotKeyID(signature: CaptureHotkeyService.signature, id: 3)
    private let fullScreenKeyID = EventHotKeyID(signature: CaptureHotkeyService.signature, id: 4)

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

    /// W e F viram atalho só enquanto o principal está segurado.
    private func registerModeKey() {
        lock.lock()
        defer { lock.unlock() }
        guard modeKeyTap == nil, modeKeyRefs.isEmpty else { return }
        if installModeKeyTap() { return }
        for (key, id) in [(kVK_ANSI_W, windowKeyID), (kVK_ANSI_F, fullScreenKeyID)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(key), 0, id, GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                modeKeyRefs.append(ref)
            }
        }
    }

    private func unregisterModeKey() {
        lock.lock()
        defer { lock.unlock() }
        modeKeyRefs.forEach { UnregisterEventHotKey($0) }
        modeKeyRefs.removeAll()
        if let modeKeyTap {
            CGEvent.tapEnable(tap: modeKeyTap, enable: false)
            if let modeKeyTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), modeKeyTapSource, .commonModes)
            }
            CFMachPortInvalidate(modeKeyTap)
        }
        modeKeyTap = nil
        modeKeyTapSource = nil
    }

    /// Liga o tap que engole W e F. Roda no laço principal, o mesmo dos
    /// eventos Carbon, então `handle` nunca é chamado em paralelo.
    private func installModeKeyTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<CaptureHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                return service.handleTapped(type: type, event: event)
            },
            userInfo: userData
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        modeKeyTap = tap
        modeKeyTapSource = source
        return true
    }

    private func handleTapped(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let modeKeyTap { CGEvent.tapEnable(tap: modeKeyTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Com ⌘, ⌃ ou ⌥ é outro atalho (⌘W fecha janela): passa adiante.
        let blocking: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard event.flags.intersection(blocking).isEmpty else { return Unmanaged.passUnretained(event) }

        let id: UInt32
        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_ANSI_W: id = windowKeyID.id
        case kVK_ANSI_F: id = fullScreenKeyID.id
        default: return Unmanaged.passUnretained(event)
        }

        // Engole também a repetição e o soltar: nada do acorde chega ao app
        // em foco.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            _ = handle(id: id, pressed: true)
        }
        return nil
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
            // A repetição automática de tecla reenviaria o "pressionado".
            guard !isMainHeld else { break }
            isMainHeld = true
            chordConsumed = false
            registerModeKey()
        case (mainID.id, false):
            isMainHeld = false
            unregisterModeKey()
            if !chordConsumed { onTriggered?() }
            chordConsumed = false
        case (windowKeyID.id, true):
            guard isMainHeld, !chordConsumed else { break }
            chordConsumed = true
            onWindowModeRequested?()
        case (fullScreenKeyID.id, true):
            guard isMainHeld, !chordConsumed else { break }
            chordConsumed = true
            onFullScreenRequested?()
        case (windowKeyID.id, false), (fullScreenKeyID.id, false):
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
