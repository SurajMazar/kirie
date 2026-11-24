import CoreGraphics
import CoreText
import Foundation
import MediaServices
import ProjectDomain
import RenderEngine

/// Review images: contact sheets, panel zooms, continuity strips and layout wireframes.
public enum ComicSheets {
    static func color(_ c: RGBAColor) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    static func crop(_ image: CGImage, _ rect: UnitRect) -> CGImage? {
        let pixels = CGRect(x: rect.x * Double(image.width), y: rect.y * Double(image.height), width: rect.width * Double(image.width),
                            height: rect.height * Double(image.height)).integral
        return image.cropping(to: pixels)
    }

    static func draw(_ image: CGImage, fitting box: CGRect, in context: CGContext) -> CGRect {
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(image, in: target)
        return target
    }

    static func statusColor(_ status: ReviewStatus) -> RGBAColor {
        switch status {
        case .pass: RGBAColor(r: 0.36, g: 0.62, b: 0.44)
        case .fail: RGBAColor(r: 0.76, g: 0.36, b: 0.34)
        case .needsReview: RGBAColor(r: 0.80, g: 0.62, b: 0.28)
        }
    }

    /// One panel at full resolution (bounded), for zoomed inspection.
    public static func panelZoom(_ image: CGImage, panel: UnitRect) -> CGImage? { crop(image, panel) }

    /// A grid of every panel with its number and review status, so cut-off characters, continuity
    /// slips and lettering mistakes can be spotted side by side.
    public static func contactSheet(_ image: CGImage, panels: [ComicPanel], columns: Int? = nil, cell: Int = 520) -> CGImage? {
        guard !panels.isEmpty else { return nil }
        let cols = max(1, columns ?? min(3, panels.count))
        let rows = Int(ceil(Double(panels.count) / Double(cols)))
        let gap = 24, label = 44
        let width = cols * cell + (cols + 1) * gap, height = rows * (cell + label) + (rows + 1) * gap
        guard let context = SampleMedia.makeContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.105, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, panel) in panels.enumerated() {
            guard let piece = crop(image, panel.rect) else { continue }
            let column = index % cols, row = index / cols
            let x = gap + column * (cell + gap)
            // CoreGraphics origin is bottom-left: lay rows out from the top.
            let top = height - gap - row * (cell + label + gap)
            let box = CGRect(x: x, y: top - label - cell, width: cell, height: cell)
            context.setFillColor(CGColor(srgbRed: 0.17, green: 0.165, blue: 0.17, alpha: 1))
            context.fill(box)
            let drawn = draw(piece, fitting: box.insetBy(dx: 6, dy: 6), in: context)
            let tint = statusColor(panel.review.status)
            context.setStrokeColor(color(tint))
            context.setLineWidth(4)
            context.stroke(drawn.insetBy(dx: -2, dy: -2))
            SampleMedia.drawText("\(index + 1)  \(panel.review.status.rawValue.replacingOccurrences(of: "_", with: " "))", in: context,
                                 center: CGPoint(x: box.midX, y: CGFloat(top) - CGFloat(label) / 2), size: 22, color: tint, font: "HelveticaNeue-Medium")
        }
        return context.makeImage()
    }

    /// The same character or prop from several panels, side by side at one consistent scale
    /// (pixels of the strip per pixel of the sheet), so size and design drift is obvious.
    public static func continuitySheet(_ image: CGImage, regions: [UnitRect], height: Int = 480) -> CGImage? {
        let pieces = regions.compactMap { crop(image, $0) }
        guard !pieces.isEmpty, let tallest = pieces.map(\.height).max(), tallest > 0 else { return nil }
        // One scale for every crop: the tallest fills the sheet height.
        let scale = CGFloat(height) / CGFloat(tallest)
        let gap: CGFloat = 20
        let widths = pieces.map { CGFloat($0.width) * scale }
        let width = Int(widths.reduce(0, +) + gap * CGFloat(pieces.count + 1))
        guard let context = SampleMedia.makeContext(width: max(1, width), height: height + Int(gap * 2)) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.105, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height + Int(gap * 2)))
        var x = gap
        context.interpolationQuality = .high
        for (index, piece) in pieces.enumerated() {
            let size = CGSize(width: widths[index], height: CGFloat(piece.height) * scale)
            // Bottom-aligned so heights compare directly.
            context.draw(piece, in: CGRect(x: x, y: gap, width: size.width, height: size.height))
            x += size.width + gap
        }
        return context.makeImage()
    }

    public struct Wireframe: Sendable {
        public var image: CGImage
        public var panels: [UnitRect]
        /// Plain-language layout description, suitable for pasting into a prompt.
        public var description: String
    }

    /// Standard layouts for 2–5 panels on a 2:3 page.
    public static func wireframeLayout(panelCount: Int) -> [UnitRect]? {
        let m = 0.035, g = 0.03
        let w = 1 - 2 * m
        func rows(_ heights: [Double], _ splits: [Int]) -> [UnitRect] {
            var rects: [UnitRect] = []
            let usable = 1 - 2 * m - g * Double(heights.count - 1)
            var y = m
            for (index, fraction) in heights.enumerated() {
                let h = usable * fraction
                let columns = splits[index]
                let cellWidth = (w - g * Double(columns - 1)) / Double(columns)
                for column in 0..<columns {
                    rects.append(UnitRect(x: m + Double(column) * (cellWidth + g), y: y, width: cellWidth, height: h))
                }
                y += h + g
            }
            return rects
        }
        switch panelCount {
        case 2: return rows([0.5, 0.5], [1, 1])
        case 3: return rows([0.34, 0.33, 0.33], [1, 1, 1])
        case 4: return rows([0.3, 0.32, 0.38], [1, 2, 1])
        case 5: return rows([0.3, 0.32, 0.38], [2, 2, 1])
        default: return nil
        }
    }

    public static func wireframe(panelCount: Int, width: Int = 1024, height: Int = 1536) -> Wireframe? {
        guard let panels = wireframeLayout(panelCount: panelCount), let context = SampleMedia.makeContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var lines = ["Layout: \(panelCount) panels on a \(width)×\(height) page (2:3). Reading order is left to right, top to bottom."]
        for (index, panel) in panels.enumerated() {
            let rect = CGRect(x: panel.x * Double(width), y: (1 - panel.maxY) * Double(height), width: panel.width * Double(width), height: panel.height * Double(height))
            context.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.setLineWidth(6)
            context.stroke(rect)
            SampleMedia.drawText("\(index + 1)", in: context, center: CGPoint(x: rect.midX, y: rect.midY), size: 120,
                                 color: RGBAColor(r: 0.75, g: 0.75, b: 0.75))
            lines.append(String(format: "Panel %d: left %.0f%%, top %.0f%%, width %.0f%%, height %.0f%% of the page.", index + 1,
                                panel.x * 100, panel.y * 100, panel.width * 100, panel.height * 100))
        }
        lines.append("Keep the gutters between panels plain and empty.")
        guard let image = context.makeImage() else { return nil }
        return Wireframe(image: image, panels: panels, description: lines.joined(separator: "\n"))
    }

    /// Evenly spaced frames of a finished reel in one image: the last check before export for
    /// cut-off characters and ghosted frames.
    public static func reelContactSheet(built: BuiltComposition, frames: Int = 12, columns: Int = 4, cellWidth: Int = 270) async throws -> CGImage? {
        let duration = built.model.duration
        guard duration.isPositive, frames > 0 else { return nil }
        let aspect = built.model.outputSize.height / max(1, built.model.outputSize.width)
        let cellHeight = Int(CGFloat(cellWidth) * aspect)
        let cols = max(1, min(columns, frames)), rows = Int(ceil(Double(frames) / Double(cols)))
        let gap = 12, label = 26
        let width = cols * cellWidth + (cols + 1) * gap, height = rows * (cellHeight + label) + (rows + 1) * gap
        guard let context = SampleMedia.makeContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.105, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<frames {
            try Task.checkCancellation()
            let time = duration.scaled(by: (Double(index) + 0.5) / Double(frames)).floored(toFrame: built.model.frameRate)
            let image = try await Exporter.still(built: built, at: time)
            let column = index % cols, row = index / cols
            let top = height - gap - row * (cellHeight + label + gap)
            let box = CGRect(x: gap + column * (cellWidth + gap), y: top - label - cellHeight, width: cellWidth, height: cellHeight)
            _ = draw(image, fitting: box, in: context)
            SampleMedia.drawText(String(format: "%.2f s", time.seconds), in: context, center: CGPoint(x: box.midX, y: CGFloat(top) - CGFloat(label) / 2),
                                 size: 15, color: RGBAColor(r: 0.72, g: 0.7, b: 0.72), font: "Menlo")
        }
        return context.makeImage()
    }
}

/// Splits a strip into feed-ready slides.
public enum CarouselExporter {
    /// One 1080×1350 slide per panel, in reading order, each panel shown whole on the page colour
    /// with a safe margin. Optionally ends with the full strip.
    public static func slides(_ image: CGImage, panels: [UnitRect], paper: RGBAColor, width: Int = 1080, height: Int = 1350,
                              margin: Double = 0.05, includeFullStrip: Bool = true) -> [CGImage] {
        var output: [CGImage] = []
        let regions = panels + (includeFullStrip ? [UnitRect.full] : [])
        for region in regions {
            guard let piece = ComicSheets.crop(image, region), let context = SampleMedia.makeContext(width: width, height: height) else { continue }
            context.setFillColor(ComicSheets.color(paper))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let inset = CGFloat(Double(min(width, height)) * margin)
            _ = ComicSheets.draw(piece, fitting: CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: inset, dy: inset), in: context)
            if let slide = context.makeImage() { output.append(slide) }
        }
        return output
    }

    /// Writes slides as `01.png`, `02.png`, … and returns their URLs.
    @discardableResult
    public static func write(_ slides: [CGImage], to directory: URL, prefix: String = "") throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, slide) in slides.enumerated() {
            let url = directory.appendingPathComponent(String(format: "%@%02d.png", prefix, index + 1))
            guard Thumbnailer.write(slide, to: url, as: .png) else { throw MediaError.decodeFailed(url.lastPathComponent, detail: "The slide could not be written.") }
            urls.append(url)
        }
        return urls
    }
}
