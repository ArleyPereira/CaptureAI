import Accelerate
import CoreGraphics
import Foundation

/// Um quadro da área capturada, em BGRA, copiado do buffer da gravação.
///
/// Copiado de propósito: o ScreenCaptureKit reaproveita os buffers, e um
/// quadro guardado por referência mudaria de conteúdo depois.
struct ScrollFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: Data

    /// Recorta as linhas `[start, end)` como imagem independente.
    func image(rows range: Range<Int>) -> CGImage? {
        let rows = range.clamped(to: 0..<height)
        guard !rows.isEmpty else { return nil }
        let slice = data.subdata(in: rows.lowerBound * bytesPerRow ..< rows.upperBound * bytesPerRow)
        guard let provider = CGDataProvider(data: slice as CFData) else { return nil }
        return CGImage(
            width: width,
            height: rows.count,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Só as colunas `range`, como quadro independente.
    func columns(_ range: Range<Int>) -> ScrollFrame {
        let rowBytes = range.count * 4
        var cropped = Data(count: rowBytes * height)
        cropped.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let target = destination.baseAddress, let base = source.baseAddress else { return }
                for row in 0..<height {
                    memcpy(target + row * rowBytes, base + row * bytesPerRow + range.lowerBound * 4, rowBytes)
                }
            }
        }
        return ScrollFrame(width: range.count, height: height, bytesPerRow: rowBytes, data: cropped)
    }
}

/// Emenda os quadros de uma rolagem numa imagem só.
///
/// Cada quadro novo é comparado com o anterior para descobrir quantas linhas
/// o conteúdo subiu; só as linhas que entraram por baixo são acrescentadas.
/// Faixas que não se mexem entre os quadros — um cabeçalho fixo no topo, uma
/// barra fixa embaixo — ficam fora da comparação: entram uma vez só, o topo no
/// começo e a base no fim, em vez de se repetirem a cada trecho.
///
/// A comparação usa uma assinatura por linha (luminância de ~96 pontos da
/// linha), não os pixels inteiros: é o bastante para achar o deslocamento e
/// barato o suficiente para acompanhar a gravação ao vivo.
final class ScrollStitcher {
    enum Step: Equatable {
        /// Primeiro quadro: vira o começo da imagem.
        case started
        /// Nada se mexeu desde o quadro anterior.
        case unchanged
        /// O conteúdo subiu e estas linhas novas entraram.
        case appended(rows: Int)
        /// O quadro não encaixa no anterior (rolou para cima, pulou longe):
        /// é ignorado, e a emenda continua de onde estava.
        case noMatch
        /// Bateu o limite de altura; nada mais entra.
        case limitReached
    }

    /// Partes da imagem final, de cima para baixo.
    private(set) var strips: [CGImage] = []
    /// Altura acumulada das partes, em pixels.
    private(set) var stitchedHeight = 0

    private let maxHeight: Int
    private var reference: ScrollFrame?
    private var referenceSignature = Signature.empty
    /// Linhas fixas na base, descobertas no primeiro encaixe.
    private var bottomBand: Int?
    /// As colunas que entram na imagem, sem as laterais paradas; decididas
    /// no primeiro quadro que muda.
    private var contentColumns: Range<Int>?

    init(maxHeight: Int = 30_000) {
        self.maxHeight = maxHeight
    }

    var isEmpty: Bool { strips.isEmpty }

    func add(_ incoming: ScrollFrame) -> Step {
        var frame = incoming
        if let columns = contentColumns {
            guard frame.width >= columns.upperBound else { return .noMatch }
            if columns != 0 ..< frame.width { frame = frame.columns(columns) }
        } else if var first = reference, first.width == frame.width, first.height == frame.height {
            // Primeiro quadro diferente do inicial: é aqui que se vê o que se
            // mexe. Colunas paradas nas laterais (a barra lateral de um app,
            // um índice ao lado do texto) não acompanham a rolagem: ficam de
            // fora da imagem, ou nenhuma linha encaixaria na do quadro
            // anterior.
            guard let columns = Self.contentColumns(from: first, to: frame) else { return .unchanged }
            contentColumns = columns
            if columns != 0 ..< frame.width {
                first = first.columns(columns)
                frame = frame.columns(columns)
                if let image = first.image(rows: 0 ..< first.height) {
                    strips = [image]
                    stitchedHeight = first.height
                }
                reference = first
                referenceSignature = Self.signature(of: first)
            }
        }
        let signature = Self.signature(of: frame)

        guard let reference else {
            guard let first = frame.image(rows: 0..<frame.height) else { return .noMatch }
            strips = [first]
            stitchedHeight = frame.height
            self.reference = frame
            referenceSignature = signature
            return .started
        }

        guard frame.width == reference.width, frame.height == reference.height else { return .noMatch }
        guard stitchedHeight < maxHeight else { return .limitReached }

        let height = frame.height
        var top = 0
        while top < height, Signature.rowsMatch(referenceSignature, top, signature, top) { top += 1 }
        if top == height { return .unchanged }
        var bottom = 0
        while bottom < height - top, Signature.rowsMatch(referenceSignature, height - 1 - bottom, signature, height - 1 - bottom) {
            bottom += 1
        }
        // A base fixa só vale a partir do primeiro encaixe: antes dele não dá
        // para distinguir uma barra fixa de conteúdo que ainda não se mexeu.
        var band = bottomBand ?? bottom
        let moving = top ..< (height - band)
        guard moving.count > 32 else { return .noMatch }

        guard let shift = Self.shift(from: referenceSignature, to: signature, in: moving) else {
            return .noMatch
        }

        if bottomBand == nil {
            band += Self.overlayRows(at: moving, shift: shift, old: referenceSignature, new: signature)
            bottomBand = band
            // A primeira parte levava a base fixa junto; ela volta só no fim.
            if band > 0, let trimmed = reference.image(rows: 0 ..< (height - band)) {
                strips[0] = trimmed
                stitchedHeight = height - band
            }
        }

        let end = height - band
        guard end - shift >= top else { return .noMatch }
        let newRows = (end - shift) ..< end
        let allowed = min(newRows.count, maxHeight - stitchedHeight)
        guard allowed > 0, let strip = frame.image(rows: newRows.lowerBound ..< (newRows.lowerBound + allowed)) else {
            return .limitReached
        }
        strips.append(strip)
        stitchedHeight += allowed
        self.reference = frame
        referenceSignature = signature
        return allowed < newRows.count ? .limitReached : .appended(rows: allowed)
    }

    /// A imagem emendada, com a base fixa (se houver) do último quadro.
    func makeImage() -> CGImage? {
        guard let reference, let first = strips.first else { return nil }
        var parts = strips
        if let band = bottomBand, band > 0, let base = reference.image(rows: (reference.height - band) ..< reference.height) {
            parts.append(base)
        }
        let width = first.width
        let height = parts.reduce(0) { $0 + $1.height }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // O contexto tem origem embaixo: a primeira parte vai no alto.
        var y = height
        for part in parts {
            y -= part.height
            context.draw(part, in: CGRect(x: 0, y: y, width: part.width, height: part.height))
        }
        return context.makeImage()
    }

    // MARK: - Colunas

    /// As colunas a manter entre dois quadros: da primeira à última que se
    /// mexe, mais as margens lisas em volta. Uma lateral parada com conteúdo
    /// (texto, ícones) fica de fora; uma margem lisa parada fica, para o
    /// conteúdo não perder o respiro. Nil quando ainda não há rolagem: só um
    /// cursor piscando ou um ícone animado não decidem nada.
    static func contentColumns(from old: ScrollFrame, to new: ScrollFrame) -> Range<Int>? {
        let width = old.width
        let rowStep = max(1, old.height / 200)
        var moving = [Bool](repeating: false, count: width)
        var busy = [Bool](repeating: false, count: width)
        old.data.withUnsafeBytes { oldRaw in
            new.data.withUnsafeBytes { newRaw in
                let a = oldRaw.bindMemory(to: UInt8.self)
                let b = newRaw.bindMemory(to: UInt8.self)
                func luminance(_ bytes: UnsafeBufferPointer<UInt8>, _ index: Int) -> Int {
                    (Int(bytes[index + 2]) * 77 + Int(bytes[index + 1]) * 150 + Int(bytes[index]) * 29) >> 8
                }
                for x in 0..<width {
                    var maxDiff = 0, low = 255, high = 0
                    for row in stride(from: 0, to: old.height, by: rowStep) {
                        let la = luminance(a, row * old.bytesPerRow + x * 4)
                        let lb = luminance(b, row * new.bytesPerRow + x * 4)
                        maxDiff = max(maxDiff, abs(la - lb))
                        low = min(low, la)
                        high = max(high, la)
                    }
                    moving[x] = maxDiff > 6
                    busy[x] = high - low > 24
                }
            }
        }
        guard moving.filter({ $0 }).count >= max(64, width / 6),
              let first = moving.firstIndex(of: true),
              let last = moving.lastIndex(of: true)
        else { return nil }

        var left = 0
        if let edge = (0 ..< first).last(where: { busy[$0] }) { left = edge + 1 }
        var right = width
        if let edge = (last + 1 ..< width).first(where: { busy[$0] }) { right = edge }
        guard right - left >= 64 else { return 0 ..< width }
        return left ..< right
    }

    // MARK: - Comparação

    /// Luminância de pontos espaçados de cada linha.
    static func signature(of frame: ScrollFrame) -> Signature {
        Signature(frame)
    }

    /// Linhas no pé da faixa que se mexe que não acompanham a rolagem.
    ///
    /// A borda translúcida da janela, a sombra de uma barra fixa ou um
    /// contorno antialiasado ficam parados, mas por cima do conteúdo: mudam
    /// a cada quadro, então não entram na base fixa, e eram justamente as
    /// linhas acrescentadas a cada emenda — a imagem saía riscada por uma
    /// linha cinza por trecho. Conteúdo de verdade reaparece `shift` linhas
    /// acima no quadro seguinte; o que não reaparece é sobreposição e passa
    /// a contar como base fixa.
    static func overlayRows(at moving: Range<Int>, shift: Int, old: Signature, new: Signature) -> Int {
        let floor = max(moving.lowerBound + shift, moving.upperBound - 48)
        var lastMismatch: Int?
        var streak = 0
        var row = moving.upperBound - 1
        while row >= floor {
            if Signature.rowsMatch(old, row, new, row - shift) {
                streak += 1
                if streak >= 6 { break }
            } else {
                lastMismatch = row
                streak = 0
            }
            row -= 1
        }
        guard let lastMismatch else { return 0 }
        // Uma linha a mais de folga para o antialiasing em volta.
        return moving.upperBound - lastMismatch + 1
    }

    /// Quantas linhas o conteúdo subiu de `old` para `new`, dentro da faixa
    /// que se mexe. Linhas distintas de `new` votam no deslocamento que as
    /// leva às iguais de `old`; os mais votados e os vizinhos deles são
    /// conferidos linha a linha, e fica o que encaixa melhor.
    ///
    /// Não basta aceitar o primeiro que passa na conferência: numa página
    /// com muito fundo liso, branco bate com branco em qualquer deslocamento,
    /// e um texto antialiasado vota quase igual no certo e no vizinho. Errar
    /// por uma linha repete (ou some com) uma linha a cada emenda, e o texto
    /// sai com o contorno dobrado.
    static func shift(from old: Signature, to new: Signature, in moving: Range<Int>) -> Int? {
        var rowsByHash: [Int: [Int]] = [:]
        for row in moving where old.distinctive[row] {
            rowsByHash[old.hashes[row], default: []].append(row)
        }

        var votes: [Int: Int] = [:]
        for row in moving where new.distinctive[row] {
            guard let candidates = rowsByHash[new.hashes[row]], candidates.count <= 6 else { continue }
            for candidate in candidates where candidate > row {
                votes[candidate - row, default: 0] += 1
            }
        }

        let minOverlap = max(16, moving.count / 10)
        let valid = 1 ... max(1, moving.count - minOverlap)
        // Empate desempatado pelo menor deslocamento, para não depender da
        // ordem do dicionário.
        let ranked = votes
            .filter { valid.contains($0.key) && $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4)
            .map(\.key)

        var candidates: [Int] = []
        for shift in ranked {
            for neighbor in (shift - 2) ... (shift + 2) where valid.contains(neighbor) && !candidates.contains(neighbor) {
                candidates.append(neighbor)
            }
        }

        var best: (shift: Int, distance: Double)?
        for shift in candidates {
            guard let distance = fit(shift, old: old, new: new, in: moving) else { continue }
            if best == nil || distance < best!.distance {
                best = (shift, distance)
            }
        }
        return best?.shift
    }

    /// Quão bem `new` encaixa em `old` subido de `shift` linhas: a diferença
    /// média nas linhas com conteúdo, ou nil se o encaixe não se sustenta.
    private static func fit(_ shift: Int, old: Signature, new: Signature, in moving: Range<Int>) -> Double? {
        let rows = moving.lowerBound ..< (moving.upperBound - shift)
        guard !rows.isEmpty else { return nil }
        let sums = Signature.rowDifferences(new, from: rows.lowerBound, old, from: rows.lowerBound + shift, rows: rows.count)
        let limit = Signature.matchLimit(new.samples)
        // Até 8% de linhas que não batem.
        let allowedMisses = rows.count - Int((Double(rows.count) * 0.92).rounded(.up))
        var misses = 0
        var distinctive = 0
        var total: Float = 0
        for (offset, sum) in sums.enumerated() {
            if sum > limit {
                misses += 1
                if misses > allowedMisses { return nil }
            }
            // Só as linhas com conteúdo dizem qual deslocamento é o certo:
            // as lisas dão diferença zero em qualquer um.
            let row = rows.lowerBound + offset
            if new.distinctive[row] || old.distinctive[row + shift] {
                distinctive += 1
                total += sum
            }
        }
        guard distinctive >= 3 else { return nil }
        return Double(total) / Double(distinctive * new.samples)
    }
}

/// A assinatura de um quadro: a luminância de ~96 pontos de cada linha,
/// numa memória só, com o que cada comparação precisa já calculado — se a
/// linha tem conteúdo e o resumo dela.
///
/// As contas vão pelo Accelerate (vDSP), que já vem otimizado: em Swift
/// puro, ponto a ponto, o build sem otimização levava de 50 a 250 ms por
/// quadro de uma janela grande, e a emenda ficava para trás da gravação.
struct Signature {
    static let samplesPerRow = 96
    static let empty = Signature(rows: 0, samples: 0, values: [], distinctive: [], hashes: [])

    let rows: Int
    let samples: Int
    /// Linha após linha, `samples` valores cada (0 a 255).
    let values: [Float]
    /// Linha com conteúdo, não um fundo liso: só essas votam no
    /// deslocamento, porque linhas lisas batem com qualquer outra lisa.
    let distinctive: [Bool]
    let hashes: [Int]

    private init(rows: Int, samples: Int, values: [Float], distinctive: [Bool], hashes: [Int]) {
        self.rows = rows
        self.samples = samples
        self.values = values
        self.distinctive = distinctive
        self.hashes = hashes
    }

    /// Pesos fixos do resumo de cada linha.
    private static let hashWeights: [Float] = (0..<samplesPerRow * 2).map { index in
        Float((index &* 2_654_435_761) % 1_000_003) / 1_000_003
    }

    init(_ frame: ScrollFrame) {
        let step = max(1, frame.width / Self.samplesPerRow)
        let samples = (frame.width + step - 1) / step
        let rows = frame.height
        var values = [Float](repeating: 0, count: rows * samples)
        var distinctive = [Bool](repeating: false, count: rows)
        var hashes = [Int](repeating: 0, count: rows)
        var channel = [Float](repeating: 0, count: samples)
        var quantized = [Float](repeating: 0, count: samples)
        let weights = Self.hashWeights
        frame.data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            values.withUnsafeMutableBufferPointer { out in
                guard let base = out.baseAddress else { return }
                let pixelStride = vDSP_Stride(step * 4)
                let count = vDSP_Length(samples)
                for row in 0..<rows {
                    let line = bytes + row * frame.bytesPerRow
                    let target = base + row * samples
                    // BGRA: luminância = 0,30 R + 0,59 G + 0,11 B.
                    vDSP_vfltu8(line + 2, pixelStride, target, 1, count)
                    var weight: Float = 77.0 / 256
                    vDSP_vsmul(target, 1, &weight, target, 1, count)
                    vDSP_vfltu8(line + 1, pixelStride, &channel, 1, count)
                    weight = 150.0 / 256
                    vDSP_vsma(channel, 1, &weight, target, 1, target, 1, count)
                    vDSP_vfltu8(line, pixelStride, &channel, 1, count)
                    weight = 29.0 / 256
                    vDSP_vsma(channel, 1, &weight, target, 1, target, 1, count)

                    var low: Float = 0, high: Float = 0
                    vDSP_minv(target, 1, &low, count)
                    vDSP_maxv(target, 1, &high, count)
                    distinctive[row] = high - low > 24

                    // Resumo da linha em faixas de 8 tons: tolera o ruído de
                    // um ou dois tons entre quadros.
                    var eighth: Float = 1.0 / 8
                    vDSP_vsmul(target, 1, &eighth, &quantized, 1, count)
                    var length = Int32(samples)
                    quantized.withUnsafeMutableBufferPointer { q in
                        vvfloorf(q.baseAddress!, q.baseAddress!, &length)
                    }
                    var dot: Float = 0
                    vDSP_dotpr(quantized, 1, weights, 1, &dot, count)
                    hashes[row] = Int(dot.bitPattern)
                }
            }
        }
        self.init(rows: rows, samples: samples, values: values, distinctive: distinctive, hashes: hashes)
    }

    /// Soma das diferenças que ainda conta como a mesma linha: média até 2.
    static func matchLimit(_ samples: Int) -> Float { Float(samples * 3) - 0.5 }

    /// A soma das diferenças de cada linha de `a` (a partir de `aRow`) com a
    /// linha correspondente de `b` (a partir de `bRow`), `rows` linhas.
    static func rowDifferences(_ a: Signature, from aRow: Int, _ b: Signature, from bRow: Int, rows: Int) -> [Float] {
        let samples = a.samples
        let count = rows * samples
        var difference = [Float](repeating: 0, count: count)
        var sums = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return sums }
        a.values.withUnsafeBufferPointer { pa in
            b.values.withUnsafeBufferPointer { pb in
                vDSP_vsub(pb.baseAddress! + bRow * samples, 1, pa.baseAddress! + aRow * samples, 1, &difference, 1, vDSP_Length(count))
            }
        }
        vDSP_vabs(difference, 1, &difference, 1, vDSP_Length(count))
        let ones = [Float](repeating: 1, count: samples)
        // Matriz linhas × pontos vezes um vetor de uns: a soma de cada linha.
        vDSP_mmul(difference, 1, ones, 1, &sums, 1, vDSP_Length(rows), 1, vDSP_Length(samples))
        return sums
    }

    /// Mesma linha nos dois quadros: diferença média de até 2 tons.
    static func rowsMatch(_ a: Signature, _ rowA: Int, _ b: Signature, _ rowB: Int) -> Bool {
        var sum: Float = 0
        a.values.withUnsafeBufferPointer { pa in
            b.values.withUnsafeBufferPointer { pb in
                var difference = [Float](repeating: 0, count: a.samples)
                vDSP_vsub(pb.baseAddress! + rowB * b.samples, 1, pa.baseAddress! + rowA * a.samples, 1, &difference, 1, vDSP_Length(a.samples))
                vDSP_svemg(difference, 1, &sum, vDSP_Length(a.samples))
            }
        }
        return sum <= matchLimit(a.samples)
    }
}
