import AppKit
import Observation
import SwiftUI

/// Ferramentas da barra do editor de captura.
enum AnnotationTool: String, CaseIterable, Identifiable {
    /// Ajustar a seleção: mover pelo miolo, redimensionar pelas alças.
    case adjust
    case rectangle
    case ellipse
    case arrow
    case marker
    case bubble

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adjust: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .marker: return "highlighter"
        case .bubble: return "text.bubble"
        }
    }

    var help: String {
        switch self {
        case .adjust: return "Ajustar seleção"
        case .rectangle: return "Retângulo"
        case .ellipse: return "Círculo"
        case .arrow: return "Seta"
        case .marker: return "Marca-texto"
        case .bubble: return "Balão de texto"
        }
    }
}

/// Modo do editor: arrastar uma área ou clicar numa janela.
enum CaptureMode {
    case area
    case window
}

/// Uma janela que pode ser capturada, como estava no instante do atalho.
struct CapturableWindow: Equatable {
    let id: CGWindowID
    /// Em coordenadas globais com origem no topo do monitor principal — o
    /// sistema do `CGWindowList` e do ScreenCaptureKit.
    let frame: CGRect
    let ownerName: String

    /// A área de trabalho entra como uma janela a mais, a do fundo. O id 0
    /// nunca é usado por uma janela de verdade.
    static func desktop(frame: CGRect) -> CapturableWindow {
        CapturableWindow(id: 0, frame: frame, ownerName: "Área de trabalho")
    }

    var isDesktop: Bool { id == 0 }

    /// Janelas comuns visíveis, da frente para trás.
    ///
    /// A ordem importa: com janelas sobrepostas, a destacada tem que ser a
    /// que está por cima no ponto do mouse. Só o `CGWindowList` garante essa
    /// ordem; a lista do ScreenCaptureKit não.
    static func onScreen() -> [CapturableWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        // As janelas do próprio CaptureAI entram como as de qualquer app — a
        // de configurações é uma janela como outra. O editor não corre risco
        // de se destacar: a lista é montada antes de ele abrir, e a miniatura
        // flutuante fica acima da camada 0, fora do filtro.
        return list.compactMap { info in
            guard
                (info[kCGWindowLayer as String] as? Int) == 0,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                let number = info[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict),
                frame.width > 60, frame.height > 40
            else { return nil }
            return CapturableWindow(
                id: number,
                frame: frame,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? ""
            )
        }
    }
}

/// Uma anotação, em pontos da tela onde foi desenhada.
struct Annotation: Identifiable {
    let id = UUID()
    let tool: AnnotationTool
    var color: NSColor
    var start: CGPoint
    var end: CGPoint
    /// Conteúdo do balão de texto. No balão, `start` e `end` coincidem: são a
    /// ponta para onde ele aponta.
    var text = ""

    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Pequena demais para valer — um clique sem arrasto.
    var isNegligible: Bool {
        if tool == .bubble { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if tool == .arrow { return hypot(end.x - start.x, end.y - start.y) < 6 }
        return rect.width < 4 || rect.height < 4
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        return copy
    }
}

/// Desenha anotações — na tela e na imagem final, com o mesmo código.
///
/// Um único desenhista garante que o arquivo salvo seja igual ao que estava
/// na tela; `map` leva o ponto do espaço da tela ao do contexto, e `scale`
/// engrossa os traços na mesma proporção dos pixels.
enum AnnotationRenderer {
    static func draw(
        _ annotation: Annotation,
        in context: CGContext,
        scale: CGFloat = 1,
        container: CGRect = .infinite,
        hideText: Bool = false,
        map: (CGPoint) -> CGPoint = { $0 }
    ) {
        if annotation.tool == .bubble {
            drawBubble(annotation, in: context, scale: scale, container: container, hideText: hideText, map: map)
            return
        }
        let start = map(annotation.start)
        let end = map(annotation.end)
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        let lineWidth = 3 * scale
        let color = annotation.color.cgColor

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .adjust, .bubble:
            return

        case .rectangle:
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            let radius = min(4 * scale, rect.width / 2, rect.height / 2)
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            context.strokePath()

        case .ellipse:
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))

        case .marker:
            context.setFillColor(annotation.color.withAlphaComponent(0.35).cgColor)
            let radius = min(3 * scale, rect.width / 2, rect.height / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()

        case .arrow:
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(14 * scale, lineWidth * 4.5)
            let spread: CGFloat = .pi / 7

            // A haste para antes da ponta: com a ponta arredondada do traço
            // passando por cima, o triângulo ficaria com um calombo.
            let shaftEnd = CGPoint(
                x: end.x - cos(angle) * head * 0.7,
                y: end.y - sin(angle) * head * 0.7
            )
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.move(to: start)
            context.addLine(to: shaftEnd)
            context.strokePath()

            context.setFillColor(color)
            context.move(to: end)
            context.addLine(to: CGPoint(
                x: end.x - cos(angle - spread) * head,
                y: end.y - sin(angle - spread) * head
            ))
            context.addLine(to: CGPoint(
                x: end.x - cos(angle + spread) * head,
                y: end.y - sin(angle + spread) * head
            ))
            context.closePath()
            context.fillPath()
        }
    }
    // MARK: - Balão de texto

    /// Geometria de um balão, no espaço do contexto onde ele vai ser desenhado.
    struct BubbleLayout {
        let bubble: CGRect
        let textRect: CGRect
        /// A ponta do rabicho — o ponto para onde o balão aponta.
        let anchor: CGPoint
        /// O balão ficou abaixo do ponto, com o rabicho saindo de cima.
        let pointsUp: Bool
        let attributed: NSAttributedString
        let font: NSFont
        let textColor: NSColor
        /// Largura máxima do texto antes de quebrar linha.
        let maxTextWidth: CGFloat
    }

    static let bubbleFillOpacity: CGFloat = 0.82

    /// Texto escuro sobre cores claras, branco sobre as demais.
    static func textColor(on fill: NSColor) -> NSColor {
        let rgb = fill.usingColorSpace(.sRGB) ?? fill
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.62 ? NSColor.black.withAlphaComponent(0.85) : .white
    }

    static func bubbleFont(scale: CGFloat) -> NSFont {
        .systemFont(ofSize: 14 * scale, weight: .medium)
    }

    /// Acima e à direita da ponta; abaixo ou para a esquerda quando não cabe.
    static func bubbleLayout(
        for annotation: Annotation,
        scale: CGFloat = 1,
        container: CGRect,
        map: (CGPoint) -> CGPoint = { $0 }
    ) -> BubbleLayout {
        let anchor = map(annotation.start)
        let font = bubbleFont(scale: scale)
        let textColor = textColor(on: annotation.color)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        // Vazio, o balão ainda precisa de uma linha de altura para receber o cursor.
        let measured = annotation.text.isEmpty ? " " : annotation.text
        let attributed = NSAttributedString(string: annotation.text, attributes: attributes)

        let maxTextWidth = 260 * scale
        let bounding = (measured as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let textSize = CGSize(width: ceil(max(bounding.width, 10 * scale)), height: ceil(bounding.height))
        let padX = 12 * scale, padY = 8 * scale, tail = 11 * scale, inset = 14 * scale
        let size = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)

        var origin = CGPoint(x: anchor.x - inset, y: anchor.y + tail)
        var pointsUp = false
        if origin.y + size.height > container.maxY {
            origin.y = anchor.y - tail - size.height
            pointsUp = true
        }
        if origin.x + size.width > container.maxX {
            origin.x = anchor.x + inset - size.width
        }
        origin.x = max(origin.x, container.minX)

        let bubble = CGRect(origin: origin, size: size)
        let textRect = CGRect(x: bubble.minX + padX, y: bubble.minY + padY, width: textSize.width, height: textSize.height)
        return BubbleLayout(
            bubble: bubble, textRect: textRect, anchor: anchor, pointsUp: pointsUp,
            attributed: attributed, font: font, textColor: textColor, maxTextWidth: maxTextWidth
        )
    }

    private static func drawBubble(
        _ annotation: Annotation,
        in context: CGContext,
        scale: CGFloat,
        container: CGRect,
        hideText: Bool,
        map: (CGPoint) -> CGPoint
    ) {
        let layout = bubbleLayout(for: annotation, scale: scale, container: container, map: map)
        let bubble = layout.bubble
        let radius = min(12 * scale, bubble.height / 2)

        // Corpo e rabicho num caminho só: preenchidos juntos, a opacidade não
        // dobra onde os dois se encontram.
        let path = CGMutablePath()
        path.addRoundedRect(in: bubble, cornerWidth: radius, cornerHeight: radius)
        let edgeY = layout.pointsUp ? bubble.maxY : bubble.minY
        let halfBase = 7 * scale
        let baseX = min(max(layout.anchor.x, bubble.minX + radius + halfBase), bubble.maxX - radius - halfBase)
        path.move(to: CGPoint(x: baseX - halfBase, y: edgeY))
        path.addLine(to: layout.anchor)
        path.addLine(to: CGPoint(x: baseX + halfBase, y: edgeY))
        path.closeSubpath()

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 8 * scale,
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.addPath(path)
        context.setFillColor(annotation.color.withAlphaComponent(bubbleFillOpacity).cgColor)
        context.fillPath()
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(1 * scale)
        context.strokePath()

        guard !hideText, !annotation.text.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        layout.attributed.draw(
            with: layout.textRect.insetBy(dx: 0, dy: 0),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}


/// Estado compartilhado entre o editor (AppKit) e a barra (SwiftUI).
@Observable
@MainActor
final class CaptureEditorModel {
    var tool: AnnotationTool = .adjust
    var color: NSColor = .systemRed
    var annotations: [Annotation] = []
    var mode: CaptureMode = .area
    /// Janelas visíveis no instante do atalho, para o modo janela.
    var windows: [CapturableWindow] = []
    /// Balão com o texto sendo digitado agora, se houver.
    var editingBubbleID: UUID?

    @ObservationIgnored var onCopy: () -> Void = {}
    @ObservationIgnored var onSave: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onCaptureWindow: (CapturableWindow) -> Void = { _ in }
    @ObservationIgnored var onOpenColorPanel: () -> Void = {}
    /// Pede redesenho e devolve o teclado ao editor depois de um clique na barra.
    @ObservationIgnored var onChange: () -> Void = {}

    func select(_ tool: AnnotationTool) {
        self.tool = tool
        onChange()
    }

    func select(_ color: NSColor) {
        self.color = color
        // Com um balão em edição, a cor vale para ele.
        if let id = editingBubbleID, let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].color = color
            onChange()
            return
        }
        // Escolher cor é a intenção de desenhar: sair do modo ajuste poupa um
        // clique a mais na ferramenta.
        if tool == .adjust { tool = .rectangle }
        onChange()
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        onChange()
    }

    func toggleMode() {
        mode = (mode == .area) ? .window : .area
        annotations = []
        onChange()
    }

    func reset(mode: CaptureMode, windows: [CapturableWindow]) {
        tool = .adjust
        annotations = []
        self.mode = mode
        self.windows = windows
    }
}

/// Barra flutuante grudada na seleção.
///
/// Sempre escura, independente do tema do app: ela flutua sobre qualquer
/// conteúdo de tela, e o vidro escuro é o que lê bem tanto sobre um site
/// branco quanto sobre um editor de código.
struct CaptureToolbar: View {
    @Bindable var model: CaptureEditorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                ToolbarIconButton(
                    icon: tool.icon,
                    help: tool.help,
                    isActive: model.tool == tool
                ) {
                    model.select(tool)
                }
            }

            separator

            Button {
                model.onOpenColorPanel()
            } label: {
                Circle()
                    .fill(Color(nsColor: model.color))
                    .frame(width: 16, height: 16)
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2) }
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cor")

            separator

            ToolbarIconButton(
                icon: "arrow.uturn.backward",
                help: "Desfazer (⌘Z)",
                isEnabled: !model.annotations.isEmpty
            ) {
                model.undo()
            }

            separator

            ToolbarIconButton(icon: "xmark", help: "Cancelar (Esc)") { model.onCancel() }
            ToolbarIconButton(icon: "square.and.arrow.down", help: "Salvar (⌘S)") { model.onSave() }

            Button {
                model.onCopy()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Copiar")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsTheme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copiar (⌘C ou Enter)")
            .padding(.leading, 4)
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.black.opacity(0.45))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 5)
    }
}

private struct ToolbarIconButton: View {
    let icon: String
    let help: String
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isActive ? SettingsTheme.accent : Color.white.opacity(isEnabled ? 0.88 : 0.3)
                )
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isActive
                                ? SettingsTheme.accent.opacity(0.2)
                                : Color.white.opacity(isHovering && isEnabled ? 0.1 : 0)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }
}
