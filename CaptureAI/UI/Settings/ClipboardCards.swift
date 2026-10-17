import AppKit
import SwiftUI

/// Um item do histórico de texto, com as ações na borda direita.
struct ClipboardEntryCard: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.kind == .link ? "link" : "text.alignleft")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            entry.kind == .link
                                ? SettingsTheme.accent
                                : SettingsTheme.tertiaryLabel(colorScheme)
                        )
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.previewLine)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                            .lineLimit(2)
                            .textSelection(.enabled)

                        if entry.lineCount > 1 {
                            Text("+\(entry.lineCount - 1) linha\(entry.lineCount > 2 ? "s" : "")")
                                .font(.system(size: 10.5))
                                .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsTheme.accent)
                    }
                }

                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: entry.createdAt))
                    if let host = entry.linkHost {
                        Text("·")
                        Text(host)
                    } else if let source = entry.sourceApp {
                        Text("·")
                        Text(source)
                    }

                    Spacer(minLength: 8)

                    // As ações só aparecem no hover: com dezenas de itens na
                    // tela, quatro botões em cada um viram ruído.
                    if isHovering {
                        actions
                            .transition(.opacity)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            iconButton(entry.isPinned ? "pin.slash" : "pin", help: entry.isPinned ? "Desafixar" : "Fixar", action: onPin)
            iconButton("pencil", help: "Editar", action: onEdit)
            iconButton(didCopy ? "checkmark" : "doc.on.doc", help: didCopy ? "Copiado" : "Copiar", tinted: didCopy) {
                onCopy()
                didCopy = true
                Task {
                    try? await Task.sleep(for: .milliseconds(1_300))
                    didCopy = false
                }
            }
            iconButton("trash", help: "Excluir", action: onDelete)
        }
    }

    private func iconButton(
        _ icon: String,
        help: String,
        tinted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tinted ? SettingsTheme.accent : SettingsTheme.secondaryLabel(colorScheme))
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SettingsTheme.ghostFill(colorScheme, pressed: false))
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Miniatura de uma captura, com as ações no hover.
struct ScreenshotCard: View {
    let entry: ScreenshotEntry
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsTheme.fieldFill(colorScheme))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }

                if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.45))
                    HStack(spacing: 8) {
                        overlayButton("doc.on.doc", help: "Copiar imagem", action: onCopy)
                        overlayButton("folder", help: "Mostrar no Finder", action: onReveal)
                        overlayButton("trash", help: "Excluir", action: onDelete)
                    }
                }
            }
            .frame(height: 112)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsTheme.cardStroke(colorScheme), lineWidth: SettingsTheme.hairline)
            }
            // Clique em qualquer ponto da miniatura abre a imagem; os botões do
            // hover, por estarem por cima, continuam com o clique deles.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: onOpen)
            .help("Abrir")

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateFormatter.string(from: entry.createdAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                if let resolution = entry.resolutionLabel {
                    Text(resolution)
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
        .task(id: entry.id) {
            thumbnail = await Self.loadThumbnail(entry.url)
        }
    }

    private func overlayButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Miniatura fora do MainActor.
    ///
    /// Decodificar a imagem inteira para um quadro de 112 pt travaria a rolagem
    /// numa pasta com muitas capturas de tela cheia.
    private static func loadThumbnail(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ]
            guard
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}

/// Folha de edição de um item do histórico.
struct ClipboardEditSheet: View {
    let entry: ClipboardEntry
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @Environment(\.colorScheme) private var colorScheme

    init(entry: ClipboardEntry, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: entry.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Editar item")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                Text("O texto editado substitui o original no histórico.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
            }

            TextEditor(text: $draft)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 180)
                .background {
                    RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                        .fill(SettingsTheme.fieldFill(colorScheme))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                        .strokeBorder(SettingsTheme.fieldStroke(colorScheme), lineWidth: SettingsTheme.hairline)
                }

            HStack {
                Spacer()
                Button("Cancelar", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") { onSave(draft) }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(SettingsBackground())
    }
}
