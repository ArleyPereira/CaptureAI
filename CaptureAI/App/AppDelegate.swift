import AppKit

/// Configura o ciclo de vida do app como acessório da barra de menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // O que sobrou de uma sessão que terminou sem fechar direito.
        DragTemporaryFiles.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Sair no meio de um download deixaria `.partial` esparsos ocupando o
        // tamanho final do pacote. Chamada síncrona: estamos na main thread, e
        // um `Task` aqui só entraria na fila enquanto o processo morre.
        ParakeetFastDownloader.purgeActivePartials()
        // Arquivos criados para soltar capturas em outros apps.
        DragTemporaryFiles.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
