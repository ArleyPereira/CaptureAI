import Foundation

/// Contrato para registro do atalho global push-to-talk.
protocol GlobalHotkeyServiceProtocol: AnyObject {
    var onPressed: (@Sendable () -> Void)? { get set }
    var onReleased: (@Sendable () -> Void)? { get set }

    /// Inicia o monitoramento com o atalho informado.
    func start(keyCode: UInt32, modifiers: UInt32)

    /// Encerra o monitoramento do atalho global.
    func stop()

    /// Troca o atalho sem derrubar os handlers (se já estiverem ativos).
    func rebind(keyCode: UInt32, modifiers: UInt32)

    /// Limpa o estado interno de “tecla segurada”.
    func resetHoldState()

    /// Força o estado de tecla segurada (após release espúrio).
    func forceHeld()
}
