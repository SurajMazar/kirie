import CoreGraphics
import Foundation
import MediaServices
import ProjectDomain

public struct PanelDetection: Sendable, Equatable {
    /// Panels in reading order, normalised with a top-left origin.
    public var panels: [UnitRect]
    /// The page colour between panels.
    public var paper: RGBAColor
}

/// RGBA8 pixels with a top-left origin.
struct PixelGrid {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage, maxSide: Int) {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        width = max(1, Int((Double(image.width) * scale).rounded()))
        height = max(1, Int((Double(image.height) * scale).rounded()))
        var storage = [UInt8](repeating: 255, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &storage, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flatten transparency onto white so see-through gutters read as paper.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = storage
    }

    @inline(__always) func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}

/// Finds comic panels from the image itself: panels are whatever is separated by clear runs of page
/// colour. Nothing is assumed about equal sizes or a grid, so strips whose rows come out at other
/// heights than their wireframe are still measured correctly.
public enum PanelDetector {
    public struct Options: Sendable {
        /// Largest side of the analysis bitmap.
        public var analysisSize = 720
        /// Per-channel tolerance (0–255) for a pixel to count as page colour.
        public var paperTolerance = 22
        /// Smallest gutter, as a fraction of the image's shorter side.
        public var minGutter = 0.006
        /// Smallest panel, as a fraction of the image area.
        public var minPanelArea = 0.012
        /// Manga order: right to left within a row.
        public var rightToLeft = false

        public init() {}
    }

    public static func detect(url: URL, options: Options = Options()) throws -> PanelDetection {
        let image = try Thumbnailer.loadImage(url, maxPixel: 4096)
        return detect(image, options: options)
    }

    public static func detect(_ image: CGImage, options: Options = Options()) -> PanelDetection {
        guard let grid = PixelGrid(image, maxSide: options.analysisSize) else {
            return PanelDetection(panels: [], paper: .paper)
        }
        let paper = paperColor(grid)
        func isPaper(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = grid.color(x, y)
            return abs(r - paper.0) <= options.paperTolerance && abs(g - paper.1) <= options.paperTolerance && abs(b - paper.2) <= options.paperTolerance
        }
        // Integral image of non-paper pixels: any rectangle's ink count in O(1).
        let w = grid.width, h = grid.height
        var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Int32 = 0
            for x in 0..<w {
                if !isPaper(x, y) { row += 1 }
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        func ink(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            Int(integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0])
        }

        let minGutter = max(2, Int(Double(min(w, h)) * options.minGutter))
        let minArea = Int(Double(w * h) * options.minPanelArea)
        var found: [(x0: Int, y0: Int, x1: Int, y1: Int)] = []

        /// Shrinks a region to its ink.
        func trimmed(_ r: (Int, Int, Int, Int)) -> (Int, Int, Int, Int)? {
            var (x0, y0, x1, y1) = r
            while y0 < y1, ink(x0, y0, x1, y0 + 1) == 0 { y0 += 1 }
            while y1 > y0, ink(x0, y1 - 1, x1, y1) == 0 { y1 -= 1 }
            while x0 < x1, ink(x0, y0, x0 + 1, y1) == 0 { x0 += 1 }
            while x1 > x0, ink(x1 - 1, y0, x1, y1) == 0 { x1 -= 1 }
            return x1 > x0 && y1 > y0 ? (x0, y0, x1, y1) : nil
        }

        /// Clear runs (gutters) across a region, along rows or columns.
        func gutters(_ r: (Int, Int, Int, Int), rows: Bool) -> [(start: Int, end: Int)] {
            let (x0, y0, x1, y1) = r
            let span = rows ? x1 - x0 : y1 - y0
            // A gutter line may contain a stray pixel or two of noise, never a panel border.
            let allowed = max(1, Int(Double(span) * 0.004))
            var runs: [(Int, Int)] = []
            var runStart: Int?
            let range = rows ? y0..<y1 : x0..<x1
            for position in range {
                let count = rows ? ink(x0, position, x1, position + 1) : ink(position, y0, position + 1, y1)
                if count <= allowed {
                    if runStart == nil { runStart = position }
                } else if let start = runStart {
                    if position - start >= minGutter { runs.append((start, position)) }
                    runStart = nil
                }
            }
            return runs
        }

        func split(_ region: (Int, Int, Int, Int), depth: Int) {
            guard let r = trimmed(region) else { return }
            let (x0, y0, x1, y1) = r
            if depth < 8 {
                for rows in [true, false] {
                    let cuts = gutters(r, rows: rows)
                    guard !cuts.isEmpty else { continue }
                    var cursor = rows ? y0 : x0
                    var pieces: [(Int, Int, Int, Int)] = []
                    for cut in cuts {
                        if cut.start > cursor { pieces.append(rows ? (x0, cursor, x1, cut.start) : (cursor, y0, cut.start, y1)) }
                        cursor = cut.end
                    }
                    let limit = rows ? y1 : x1
                    if limit > cursor { pieces.append(rows ? (x0, cursor, x1, limit) : (cursor, y0, limit, y1)) }
                    guard pieces.count > 1 else { continue }
                    if !rows, options.rightToLeft { pieces.reverse() }
                    for piece in pieces { split(piece, depth: depth + 1) }
                    return
                }
            }
            if (x1 - x0) * (y1 - y0) >= minArea, x1 - x0 >= minGutter * 3, y1 - y0 >= minGutter * 3 {
                found.append((x0, y0, x1, y1))
            }
        }
        split((0, 0, w, h), depth: 0)

        let panels = found.map {
            UnitRect(x: Double($0.x0) / Double(w), y: Double($0.y0) / Double(h), width: Double($0.x1 - $0.x0) / Double(w),
                     height: Double($0.y1 - $0.y0) / Double(h)).clamped()
        }
        return PanelDetection(panels: panels, paper: RGBAColor(r: Double(paper.0) / 255, g: Double(paper.1) / 255, b: Double(paper.2) / 255))
    }

    /// The page colour: the most common colour along the image's outer edge.
    static func paperColor(_ grid: PixelGrid) -> (Int, Int, Int) {
        var histogram: [Int: Int] = [:]
        func add(_ x: Int, _ y: Int) {
            let (r, g, b) = grid.color(x, y)
            // Quantise to 4 bits per channel so near-identical shades vote together.
            histogram[(r >> 4) << 8 | (g >> 4) << 4 | (b >> 4), default: 0] += 1
        }
        let inset = min(2, min(grid.width, grid.height) / 4)
        for x in 0..<grid.width { add(x, inset); add(x, grid.height - 1 - inset) }
        for y in 0..<grid.height { add(inset, y); add(grid.width - 1 - inset, y) }
        guard let bucket = histogram.max(by: { $0.value < $1.value })?.key else { return (255, 255, 255) }
        // Average the actual colours in the winning bucket.
        var sum = (0, 0, 0), count = 0
        func collect(_ x: Int, _ y: Int) {
            let (r, g, b) = grid.color(x, y)
            if (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4) == bucket { sum.0 += r; sum.1 += g; sum.2 += b; count += 1 }
        }
        for x in 0..<grid.width { collect(x, inset); collect(x, grid.height - 1 - inset) }
        for y in 0..<grid.height { collect(inset, y); collect(grid.width - 1 - inset, y) }
        return count > 0 ? (sum.0 / count, sum.1 / count, sum.2 / count) : (255, 255, 255)
    }
}
