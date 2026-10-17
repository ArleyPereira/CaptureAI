import AppKit
import AVFoundation
import Foundation

/// Gerencia a permissão de microfone do sistema.
enum MicrophonePermission {
    /// Status atual da autorização de áudio.
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isAuthorized: Bool {
        status == .authorized
    }

    /// Solicita permissão de microfone, se ainda não determinada.
    static func requestAccess() async -> Bool {
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    /// Abre as configurações de privacidade do microfone no macOS.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ]

        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
}
