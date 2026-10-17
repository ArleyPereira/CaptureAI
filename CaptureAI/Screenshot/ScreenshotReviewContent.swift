import AppKit
import SwiftUI

/// Um realce desenhado por cima da captura, em coordenadas relativas (0…1).
///
/// Relativas e não em pixels: a imagem é exibida escalada para caber na
/// janela, e a janela é redimensionável. Guardando a fração, o mesmo retângulo
/// vale na tela e na hora de gravar na resolução original.
private struct Highlight: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect
    var style: HighlightStyle
}

enum HighlightStyle: String, CaseIterable, Identifiable {
    case marker
    case box

    var id: String { rawValue }

    var title: String {
        switch self {
        case .marker: return "Marcador"
        case .box: return "Moldura"
        }
    }

    var icon: String {
        switch self {
        case .marker: return "highlighter"
        case .box: return "rectangle.dashed"
        }
    }
}

/// Revisão pós-captura: ver, destacar e decidir o destino.
struct ScreenshotReviewContent: View {
    let image: NSImage
    let onDecision: (ScreenshotReviewDecision) -> Void

    @State private var highlights: [Highlight] = []
    @State private var draft: CGRect?
    @State private var style: HighlightStyle = .marker
    @State private var isAnnotating = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SettingsDivider()
            canvas
            SettingsDivider()
            actions
        }
        .background(SettingsBackground())
    }

    // MARK: - Barra superior

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(resolutionLabel, systemImage: "viewfinder")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))

            Spacer(minLength: 12)

            Button {
                isAnnotating.toggle()
            } label: {
                Label(
                    isAnnotating ? "Destacando" : "Destacar",
                    systemImage: "highlighter"
                )
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(GhostButtonStyle())
            .help("Arraste sobre a imagem para destacar um trecho")

            if isAnnotating {
                Picker("", selection: $style) {
                    ForEach(HighlightStyle.allCases) { option in
                        Image(systemName: option.icon).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
            }

            if !highlights.isEmpty {
                Button {
                    highlights.removeLast()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle())
                .help("Desfazer o último destaque")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Imagem

    private var canvas: some View {
        GeometryReader { geo in
            let frame = Self.fittedRect(for: image.size, in: geo.size)

            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)

                ForEach(highlights) { item in
                    shape(for: item, in: frame)
                }
                if let draft {
                    shape(for: Highlight(rect: draft, style: style), in: frame)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(isAnnotating ? dragGesture(in: frame) : nil)
        }
        .padding(10)
    }

    private func dragGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draft = Self.normalized(
                    from: value.startLocation,
                    to: value.location,
                    in: frame
                )
            }
            .onEnded { value in
                let rect = Self.normalized(from: value.startLocation, to: value.location, in: frame)
                // Um clique sem arrasto vira um retângulo de área zero, que
                // ficaria invisível na imagem e no arquivo salvo.
                if rect.width > 0.005, rect.height > 0.005 {
                    highlights.append(Highlight(rect: rect, style: style))
                }
                draft = nil
            }
    }

    @ViewBuilder
    private func shape(for item: Highlight, in frame: CGRect) -> some View {
        let rect = CGRect(
            x: frame.minX + item.rect.minX * frame.width,
            y: frame.minY + item.rect.minY * frame.height,
            width: item.rect.width * frame.width,
            height: item.rect.height * frame.height
        )

        switch item.style {
        case .marker:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.yellow.opacity(0.35))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        case .box:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(SettingsTheme.accent, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    // MARK: - Ações

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button("Descartar") { onDecision(.discard) }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button {
                onDecision(.copy(image: rendered()))
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(GhostButtonStyle())
            .keyboardShortcut("c", modifiers: .command)

            Button {
                onDecision(.save(image: rendered()))
            } label: {
                Label("Salvar", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(SettingsTheme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var resolutionLabel: String {
        "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    // MARK: - Renderização final

    /// Grava os destaques dentro da imagem, na resolução original.
    ///
    /// Sem destaque nenhum devolve a imagem intacta — reencodar à toa só
    /// perderia qualidade e metadados.
    private func rendered() -> NSImage {
        guard !highlights.isEmpty else { return image }

        let size = image.size
        let output = NSImage(size: size)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))

        for item in highlights {
            // O eixo Y do SwiftUI cresce para baixo; o do AppKit, para cima.
            let rect = NSRect(
                x: item.rect.minX * size.width,
                y: size.height - (item.rect.maxY * size.height),
                width: item.rect.width * size.width,
                height: item.rect.height * size.height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            switch item.style {
            case .marker:
                NSColor.systemYellow.withAlphaComponent(0.35).setFill()
                path.fill()
            case .box:
                NSColor(SettingsTheme.accent).setStroke()
                path.lineWidth = max(2, size.width / 400)
                path.stroke()
            }
        }

        output.unlockFocus()
        return output
    }

    // MARK: - Geometria

    /// Onde a imagem fica depois de caber na área, preservando a proporção.
    private static func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Converte um arrasto na tela para fração da imagem, preso às bordas.
    private static func normalized(from start: CGPoint, to end: CGPoint, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let x1 = ((min(start.x, end.x) - frame.minX) / frame.width).clamped()
        let x2 = ((max(start.x, end.x) - frame.minX) / frame.width).clamped()
        let y1 = ((min(start.y, end.y) - frame.minY) / frame.height).clamped()
        let y2 = ((max(start.y, end.y) - frame.minY) / frame.height).clamped()
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

private extension CGFloat {
    func clamped() -> CGFloat { Swift.min(1, Swift.max(0, self)) }
}
