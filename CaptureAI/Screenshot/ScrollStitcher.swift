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
    private var referenceSignature: [[UInt8]] = []
    /// Linhas fixas na base, descobertas no primeiro encaixe.
    private var bottomBand: Int?

    init(maxHeight: Int = 30_000) {
        self.maxHeight = maxHeight
    }

    var isEmpty: Bool { strips.isEmpty }

    func add(_ frame: ScrollFrame) -> Step {
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
        while top < height, Self.rowsMatch(referenceSignature[top], signature[top]) { top += 1 }
        if top == height { return .unchanged }
        var bottom = 0
        while bottom < height - top, Self.rowsMatch(referenceSignature[height - 1 - bottom], signature[height - 1 - bottom]) {
            bottom += 1
        }
        // A base fixa só vale a partir do primeiro encaixe: antes dele não dá
        // para distinguir uma barra fixa de conteúdo que ainda não se mexeu.
        let band = bottomBand ?? bottom
        let moving = top ..< (height - band)
        guard moving.count > 32 else { return .noMatch }

        guard let shift = Self.shift(from: referenceSignature, to: signature, in: moving) else {
            return .noMatch
        }

        if bottomBand == nil {
            bottomBand = band
            // A primeira parte levava a base fixa junto; ela volta só no fim.
            if band > 0, let trimmed = reference.image(rows: 0 ..< (height - band)) {
                strips[0] = trimmed
                stitchedHeight = height - band
            }
        }

        let newRows = (moving.upperBound - shift) ..< moving.upperBound
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

    // MARK: - Comparação

    private static let samplesPerRow = 96

    /// Luminância de pontos espaçados de cada linha.
    static func signature(of frame: ScrollFrame) -> [[UInt8]] {
        let step = max(1, frame.width / samplesPerRow)
        return frame.data.withUnsafeBytes { raw -> [[UInt8]] in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (0..<frame.height).map { row in
                let base = row * frame.bytesPerRow
                return stride(from: 0, to: frame.width, by: step).map { column in
                    let index = base + column * 4
                    // BGRA.
                    let b = Int(bytes[index]), g = Int(bytes[index + 1]), r = Int(bytes[index + 2])
                    return UInt8((r * 77 + g * 150 + b * 29) >> 8)
                }
            }
        }
    }

    private static func rowsMatch(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        difference(a, b) <= 2
    }

    /// Diferença média absoluta entre duas linhas.
    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var total = 0
        for index in 0..<min(a.count, b.count) {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return total / max(1, a.count)
    }

    /// Uma linha com conteúdo, não um fundo liso: só essas servem para votar
    /// no deslocamento, porque linhas lisas batem com qualquer outra lisa.
    private static func isDistinctive(_ row: [UInt8]) -> Bool {
        guard let low = row.min(), let high = row.max() else { return false }
        return Int(high) - Int(low) > 24
    }

    private static func hash(_ row: [UInt8]) -> Int {
        var hasher = Hasher()
        for value in row { hasher.combine(value >> 3) }
        return hasher.finalize()
    }

    /// Quantas linhas o conteúdo subiu de `old` para `new`, dentro da faixa
    /// que se mexe. Linhas distintas de `new` votam no deslocamento que as
    /// leva às iguais de `old`; o mais votado é conferido linha a linha.
    static func shift(from old: [[UInt8]], to new: [[UInt8]], in moving: Range<Int>) -> Int? {
        var rowsByHash: [Int: [Int]] = [:]
        for row in moving where isDistinctive(old[row]) {
            rowsByHash[hash(old[row]), default: []].append(row)
        }

        var votes: [Int: Int] = [:]
        for row in moving where isDistinctive(new[row]) {
            guard let candidates = rowsByHash[hash(new[row])], candidates.count <= 6 else { continue }
            for candidate in candidates where candidate > row {
                votes[candidate - row, default: 0] += 1
            }
        }

        let minOverlap = max(16, moving.count / 10)
        let ranked = votes
            .filter { $0.key <= moving.count - minOverlap && $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(4)

        for (shift, _) in ranked {
            var compared = 0
            var matched = 0
            for row in moving.lowerBound ..< (moving.upperBound - shift) {
                compared += 1
                if rowsMatch(new[row], old[row + shift]) { matched += 1 }
            }
            if compared > 0, Double(matched) / Double(compared) >= 0.92 {
                return shift
            }
        }
        return nil
    }
}
