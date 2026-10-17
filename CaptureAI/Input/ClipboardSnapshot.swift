import AppKit
import Foundation

extension NSPasteboard.PasteboardType {
    /// Convenção do nspasteboard.org: marca conteúdo de passagem, que os
    /// gerenciadores de clipboard devem ignorar em vez de guardar no histórico.
    ///
    /// A ditagem só está no clipboard porque o ⌘V é a forma mais rápida de
    /// entregá-la ao app — ela não é algo que o usuário copiou, e poluir o
    /// histórico dele com isso é efeito colateral, não funcionalidade. É a
    /// mesma marca que o Spokenly usa (confirmado no binário dele).
    ///
    /// Respeitada pelo histórico de clipboard do Spotlight (macOS 26) e por
    /// Raycast, Maccy, Alfred, Paste, LaunchBar e afins.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}

/// Snapshot do conteúdo atual do clipboard, para restaurar após o paste.
struct ClipboardSnapshot {
    private let items: [NSPasteboardItem]

    /// Captura uma cópia profunda dos itens atuais do clipboard geral.
    static func capture(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let cloned: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var wroteSomething = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    wroteSomething = true
                }
            }
            return wroteSomething ? copy : nil
        }
        return ClipboardSnapshot(items: cloned)
    }

    /// Restaura o snapshot no clipboard informado.
    func restore(into pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
