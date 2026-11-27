import AVFoundation
import CoreAudio
import Foundation
import Observation

/// Microfone conectado, como aparece na escolha das configurações.
struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    /// `AVCaptureDevice.uniqueID` (o mesmo UID do CoreAudio).
    let uid: String
    let name: String

    var id: String { uid }
}

/// O microfone escolhido não estava conectado e a captura foi para o padrão.
struct MicrophoneFallback: Equatable, Sendable {
    /// Nome do microfone escolhido nas configurações.
    let missingName: String
    /// Nome do microfone que está gravando no lugar dele.
    let usingName: String

    var title: String {
        "\(missingName) não está conectado"
    }

    var hint: String {
        "Usando \(usingName)."
    }

    var message: String {
        "\(missingName) não está conectado, usando \(usingName). Para trocar, abra Configurações → Transcrição → Microfone."
    }
}

/// Lista de microfones e a escolha salva, sem depender do MainActor.
///
/// O gravador consulta daqui na fila de configuração da captura; a tela das
/// configurações, no MainActor. `UserDefaults` e `DiscoverySession` aceitam os
/// dois.
nonisolated enum MicrophoneCatalog {
    /// Chaves no `UserDefaults` (as mesmas que `AppSettings` grava).
    static let preferredUIDKey = "settings.microphoneUID"
    static let preferredNameKey = "settings.microphoneName"

    /// UID escolhido nas configurações; `nil` = padrão do macOS.
    static var preferredUID: String? {
        let uid = UserDefaults.standard.string(forKey: preferredUIDKey)
        return uid?.isEmpty == false ? uid : nil
    }

    /// Nome do escolhido quando foi salvo, para avisar mesmo desconectado.
    static var preferredName: String? {
        UserDefaults.standard.string(forKey: preferredNameKey)
    }

    /// Microfones conectados agora, na ordem do sistema.
    static func connectedCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.filter(\.isConnected)
    }

    /// Os que o usuário pode escolher: os mesmos que Ajustes do Sistema → Som
    /// mostra em Entrada.
    ///
    /// Drivers virtuais (o "Microsoft Teams Audio", por exemplo) aparecem para
    /// o AVFoundation, mas se declaram impróprios para padrão de entrada e o
    /// macOS os esconde; listá-los aqui seria oferecer um "microfone" que não
    /// capta voz.
    static func connectedDevices() -> [MicrophoneDevice] {
        var seen = Set<String>()
        return connectedCaptureDevices().compactMap { device in
            guard isSelectableInput(uid: device.uniqueID) else { return nil }
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return MicrophoneDevice(uid: device.uniqueID, name: device.localizedName)
        }
    }

    private static func isSelectableInput(uid: String) -> Bool {
        guard let deviceID = SystemAudioDevice.deviceID(forUID: uid) else { return true }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return true }
        var canBeDefault: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &canBeDefault) == noErr else {
            return true
        }
        return canBeDefault != 0
    }

    /// Nome do microfone padrão do macOS agora.
    @MainActor static func defaultDeviceName(among devices: [MicrophoneDevice]) -> String? {
        if let uid = SystemAudioDevice.defaultInputDeviceUID,
           let match = devices.first(where: { $0.uid == uid }) {
            return match.name
        }
        return SystemAudioDevice.defaultInputDeviceName
    }
}

/// Acompanha os microfones conectados e o padrão do macOS para a tela das
/// configurações: conectar ou tirar um aparelho atualiza a lista na hora.
@Observable
@MainActor
final class MicrophoneDeviceMonitor {
    static let shared = MicrophoneDeviceMonitor()

    private(set) var devices: [MicrophoneDevice] = []
    /// Nome do microfone padrão do macOS (o "Usando: …").
    private(set) var defaultDeviceName: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var coreAudioListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var lateRefreshTask: Task<Void, Never>?

    private static let systemAddresses: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    private init() {
        refresh()
        startObserving()
    }

    func refresh() {
        let current = MicrophoneCatalog.connectedDevices()
        if current != devices {
            devices = current
        }
        let name = MicrophoneCatalog.defaultDeviceName(among: current)
        if name != defaultDeviceName {
            defaultDeviceName = name
        }
    }

    private func startObserving() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }

        // O padrão do macOS muda sem nenhum aparelho entrar ou sair (o usuário
        // troca em Ajustes): só o CoreAudio avisa disso.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        for var address in Self.systemAddresses {
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                block
            )
        }
        coreAudioListener = block
    }

    /// Relê agora e de novo logo depois: o CoreAudio avisa antes de a lista do
    /// AVFoundation incluir (ou tirar) o aparelho.
    private func scheduleRefresh() {
        refresh()
        lateRefreshTask?.cancel()
        lateRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
