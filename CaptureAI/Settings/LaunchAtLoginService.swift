import Foundation
import ServiceManagement

/// Liga/desliga a abertura do CaptureAI no login do macOS (`SMAppService`).
enum LaunchAtLoginService {
    /// `true` quando o app está registrado para iniciar com o usuário.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Mensagem amigável quando o status não é simplesmente ligado/desligado.
    static var statusHint: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            return "Confirme o CaptureAI em Ajustes do Sistema → Geral → Itens de Início e Extensões."
        case .notFound:
            return "Instale o app em Aplicativos para habilitar o início automático."
        default:
            return nil
        }
    }

    /// Registra ou remove o CaptureAI dos itens de início.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
