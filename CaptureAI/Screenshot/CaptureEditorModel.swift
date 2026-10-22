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
    case pen
    case marker
    case bubble

    var id: String { rawValue }

    /// Usa a espessura escolhida na barra. O marca-texto cobre a área
    /// arrastada e o balão tem desenho próprio: espessura não faz sentido.
    var usesLineWidth: Bool {
        switch self {
        case .rectangle, .ellipse, .arrow, .pen: return true
        case .adjust, .marker, .bubble: return false
        }
    }

    var icon: String {
        switch self {
        case .adjust: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "paintbrush.pointed"
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
        case .pen: return "Pincel"
        case .marker: return "Marca-texto"
        case .bubble: return "Balão de texto"
        }
    }
}

/// Espessuras do traço, da barra do editor.
enum StrokeWidth: CGFloat, CaseIterable, Identifiable {
    case thin = 3
    case medium = 8
    case thick = 18

    var id: CGFloat { rawValue }

    /// Diâmetro do ponto que representa a espessura na barra.
    var dotSize: CGFloat {
        switch self {
        case .thin: return 4
        case .medium: return 7
        case .thick: return 11
        }
    }

    var help: String {
        switch self {
        case .thin: return "Traço fino"
        case .medium: return "Traço médio"
        case .thick: return "Traço grosso"
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

        // Camadas abaixo do Dock: além da comum (0), entram as flutuantes e
        // os painéis modais. O macOS sobe uma modal para a camada 8 enquanto
        // o app dono está em foco — a de login do Teams sumia da lista e o
        // clique caía na janela principal, logo atrás.
        //
        // As janelas do próprio CaptureAI entram como as de qualquer app,
        // inclusive a barra flutuante de gravação. A miniatura fica acima do
        // Dock, fora do filtro, e o editor e o seletor de cor só abrem depois
        // de a lista ser montada.
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        return list.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                (0..<dockLayer).contains(layer),
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
    var lineWidth: CGFloat = StrokeWidth.thin.rawValue
    /// Trajeto do pincel, na ordem em que foi desenhado.
    var points: [CGPoint] = []
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
        // Um clique com o pincel deixa um ponto, e isso já é uma marca.
        if tool == .pen { return points.isEmpty }
        return rect.width < 4 || rect.height < 4
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
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
        let lineWidth = annotation.lineWidth * scale
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

        case .pen:
            drawPen(annotation.points.map(map), color: color, lineWidth: lineWidth, in: context)

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

    /// Traço livre suavizado: curvas pelos pontos médios entre as amostras,
    /// para o trajeto do mouse não sair serrilhado.
    private static func drawPen(_ points: [CGPoint], color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        guard let first = points.first else { return }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.move(to: first)
        if points.count == 1 {
            // Clique sem arrasto: o traço de comprimento zero com ponta
            // redonda vira um ponto.
            context.addLine(to: first)
        } else {
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                context.addQuadCurve(to: mid, control: previous)
            }
            context.addLine(to: points[points.count - 1])
        }
        context.strokePath()
    }

    // MARK: - Balão de texto

    /// Geometria de um balão, no espaço do contexto onde ele vai ser desenhado.
    struct BubbleLayout {
        /// Contorno único — corpo e rabicho na mesma linha, sem emenda.
        let path: CGPath
        let bubble: CGRect
        let textRect: CGRect
        let attributed: NSAttributedString
        /// Largura máxima do texto antes de quebrar linha.
        let maxTextWidth: CGFloat
    }

    /// Grafite: o mesmo em qualquer fundo, e sem disputar atenção com o
    /// conteúdo capturado. Não segue a cor da barra de propósito — uma cor viva
    /// num balão cheio de texto fica pesada.
    static let bubbleTextColor = NSColor.white
    private static let bubbleTop = NSColor(red: 0.21, green: 0.22, blue: 0.25, alpha: 0.95)
    private static let bubbleBottom = NSColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 0.95)

    static func bubbleFont(scale: CGFloat) -> NSFont {
        .systemFont(ofSize: 14 * scale, weight: .medium)
    }

    /// Acima e à direita da ponta; espelhado para baixo ou para a esquerda
    /// quando não cabe no recipiente.
    static func bubbleLayout(
        for annotation: Annotation,
        scale: CGFloat = 1,
        container: CGRect,
        map: (CGPoint) -> CGPoint = { $0 }
    ) -> BubbleLayout {
        let anchor = map(annotation.start)
        let font = bubbleFont(scale: scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: bubbleTextColor]
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
        let padX = 14 * scale, padY = 10 * scale
        let size = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)

        // Primeiro na orientação padrão; espelha o eixo que estourar.
        var (path, bubble) = bubbleShape(size: size, scale: scale, anchor: anchor, flipX: false, flipY: false)
        let flipY = bubble.maxY > container.maxY
        let flipX = bubble.maxX > container.maxX
        if flipX || flipY {
            (path, bubble) = bubbleShape(size: size, scale: scale, anchor: anchor, flipX: flipX, flipY: flipY)
        }

        let textRect = CGRect(x: bubble.minX + padX, y: bubble.minY + padY, width: textSize.width, height: textSize.height)
        return BubbleLayout(path: path, bubble: bubble, textRect: textRect, attributed: attributed, maxTextWidth: maxTextWidth)
    }

    /// Monta o contorno com a ponta na origem e o balão acima e à direita, e
    /// leva ao lugar certo por espelhamento: as quatro orientações saem de um
    /// desenho só, todas com a mesma curva.
    private static func bubbleShape(
        size: CGSize, scale: CGFloat, anchor: CGPoint, flipX: Bool, flipY: Bool
    ) -> (CGPath, CGRect) {
        let r = 13 * scale, tail = 13 * scale, base = 20 * scale
        let body = CGRect(x: -r + 3 * scale, y: tail, width: size.width, height: size.height)
        let baseStart = body.minX + r - 1 * scale
        let baseEnd = baseStart + base

        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX, y: body.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + r))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX - r, y: body.minY), radius: r)
        path.addLine(to: CGPoint(x: baseEnd, y: body.minY))
        // Desce saindo na horizontal — sem quina na junção — até a ponta.
        path.addCurve(
            to: .zero,
            control1: CGPoint(x: baseEnd - base * 0.55, y: body.minY),
            control2: CGPoint(x: 4 * scale, y: tail * 0.35)
        )
        // Sobe chegando na lateral já na vertical: tangente contínua, sem vinco.
        path.addCurve(
            to: CGPoint(x: body.minX, y: body.minY + r),
            control1: CGPoint(x: -3 * scale, y: tail * 0.55),
            control2: CGPoint(x: body.minX, y: body.minY + 1 * scale)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - r))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX + r, y: body.maxY), radius: r)
        path.closeSubpath()

        var transform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .scaledBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
        let placed = path.copy(using: &transform) ?? path
        return (placed, body.applying(transform))
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

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -5 * scale),
            blur: 18 * scale,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        context.addPath(layout.path)
        context.setFillColor(bubbleBottom.cgColor)
        context.fillPath()
        context.restoreGState()

        // Degradê suave de cima para baixo, recortado pelo contorno.
        context.saveGState()
        context.addPath(layout.path)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [bubbleTop.cgColor, bubbleBottom.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: layout.bubble.maxY),
                end: CGPoint(x: 0, y: layout.bubble.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()

        context.addPath(layout.path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        context.setLineWidth(1 * scale)
        context.strokePath()

        guard !hideText, !annotation.text.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        layout.attributed.draw(with: layout.textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
}


/// Estado compartilhado entre o editor (AppKit) e a barra (SwiftUI).
@Observable
@MainActor
final class CaptureEditorModel {
    var tool: AnnotationTool = .adjust
    var color: NSColor = .systemRed
    var lineWidth: StrokeWidth = .thin
    var annotations: [Annotation] = []
    var mode: CaptureMode = .area
    /// Janelas visíveis no instante do atalho, para o modo janela.
    var windows: [CapturableWindow] = []
    /// Balão com o texto sendo digitado agora, se houver.
    var editingBubbleID: UUID?

    @ObservationIgnored var onCopy: () -> Void = {}
    @ObservationIgnored var onSave: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onFullScreen: () -> Void = {}
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

    func select(_ width: StrokeWidth) {
        lineWidth = width
        // Como na cor: escolher espessura é intenção de desenhar com traço.
        if !tool.usesLineWidth { tool = .pen }
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

            HStack(spacing: 0) {
                ForEach(StrokeWidth.allCases) { width in
                    StrokeWidthButton(
                        width: width,
                        isActive: model.lineWidth == width,
                        isEnabled: model.tool.usesLineWidth || model.tool == .adjust
                    ) {
                        model.select(width)
                    }
                }
            }

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

/// Um tamanho de traço, mostrado como um ponto do diâmetro correspondente.
private struct StrokeWidthButton: View {
    let width: StrokeWidth
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isActive ? SettingsTheme.accent : Color.white.opacity(isEnabled ? 0.88 : 0.35))
                .frame(width: width.dotSize, height: width.dotSize)
                .frame(width: 24, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isActive
                                ? SettingsTheme.accent.opacity(0.2)
                                : Color.white.opacity(isHovering ? 0.1 : 0)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(width.help)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
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
