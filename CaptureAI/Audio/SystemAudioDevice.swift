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
