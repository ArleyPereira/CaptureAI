import CoreAudio
import Foundation

/// Acesso ao dispositivo de entrada padrão do macOS.
enum SystemAudioDevice {
    /// ID do microfone definido como padrão no sistema.
    static var defaultInputDeviceID: AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return kAudioObjectUnknown
        }
        return deviceID
    }

    /// Nome amigável do dispositivo padrão.
    static var defaultInputDeviceName: String? {
        stringProperty(kAudioObjectPropertyName)
    }

    /// UID do dispositivo padrão, usado para casar com `AVCaptureDevice.uniqueID`.
    static var defaultInputDeviceUID: String? {
        stringProperty(kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Mudo

    /// Propriedades de entrada que indicam microfone calado.
    ///
    /// Nem todo dispositivo publica as duas: o embutido do Mac tem volume e
    /// não tem mudo; muitos USB e headsets têm mudo físico.
    static let inputMuteAddresses: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    /// Converte o UID (o `uniqueID` do `AVCaptureDevice`) no ID do CoreAudio.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// `true` se a entrada está mutada ou com volume zerado.
    static func isInputMuted(_ deviceID: AudioDeviceID) -> Bool {
        var muteAddress = inputMuteAddresses[0]
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &muted) == noErr,
               muted != 0 {
                return true
            }
        }

        var volumeAddress = inputMuteAddresses[1]
        if AudioObjectHasProperty(deviceID, &volumeAddress) {
            var volume: Float32 = 1
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &volume) == noErr,
               volume <= 0.001 {
                return true
            }
        }
        return false
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector) -> String? {
        let deviceID = defaultInputDeviceID
        guard deviceID != kAudioObjectUnknown else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfValue: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfValue) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let cfValue else { return nil }
        return cfValue.takeRetainedValue() as String
    }
}
