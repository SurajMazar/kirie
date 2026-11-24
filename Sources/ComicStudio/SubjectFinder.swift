import CoreGraphics
import Foundation
import ProjectDomain
import Vision

/// Finds what must stay in frame inside a panel.
public enum SubjectFinder {
    /// Bounds of everything in a panel that is not its background, panel-normalised.
    ///
    /// The background is the panel's most common colour (ignoring its border). This is deliberately
    /// conservative: it includes characters, props and lettering, which is exactly the set of things
    /// a reel must not crop.
    public static func contentBounds(in image: CGImage, panel: UnitRect, tolerance: Int = 30) -> UnitRect? {
        let rect = CGRect(x: panel.x * Double(image.width), y: panel.y * Double(image.height), width: panel.width * Double(image.width),
                          height: panel.height * Double(image.height)).integral
        guard rect.width >= 8, rect.height >= 8, let cropped = image.cropping(to: rect), let grid = PixelGrid(cropped, maxSide: 320) else { return nil }
        let w = grid.width, h = grid.height
        // Ignore the outer 6% so the panel border does not count as content.
        let insetX = max(2, Int(Double(w) * 0.06)), insetY = max(2, Int(Double(h) * 0.06))
        guard w > insetX * 2 + 4, h > insetY * 2 + 4 else { return nil }
        var histogram: [Int: Int] = [:]
        for y in stride(from: insetY, to: h - insetY, by: 2) {
            for x in stride(from: insetX, to: w - insetX, by: 2) {
                let (r, g, b) = grid.color(x, y)
                histogram[(r >> 4) << 8 | (g >> 4) << 4 | (b >> 4), default: 0] += 1
            }
        }
        guard let bucket = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        let background = (((bucket >> 8) & 0xF) * 16 + 8, ((bucket >> 4) & 0xF) * 16 + 8, (bucket & 0xF) * 16 + 8)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in insetY..<(h - insetY) {
            for x in insetX..<(w - insetX) {
                let (r, g, b) = grid.color(x, y)
                if abs(r - background.0) > tolerance || abs(g - background.1) > tolerance || abs(b - background.2) > tolerance {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return UnitRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h), width: Double(maxX - minX + 1) / Double(w),
                        height: Double(maxY - minY + 1) / Double(h)).clamped()
    }

    /// Where a viewer's eye lands, panel-normalised, from on-device Vision saliency. Nil when Vision
    /// finds nothing or is unavailable; callers fall back to the centre of the content bounds.
    public static func attentionPoint(in image: CGImage, panel: UnitRect) -> UnitPoint2D? {
        let rect = CGRect(x: panel.x * Double(image.width), y: panel.y * Double(image.height), width: panel.width * Double(image.width),
                          height: panel.height * Double(image.height)).integral
        guard rect.width >= 16, rect.height >= 16, let cropped = image.cropping(to: rect) else { return nil }
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first,
              let objects = observation.salientObjects, !objects.isEmpty else { return nil }
        var union = CGRect.null
        for object in objects { union = union.union(object.boundingBox) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return nil }
        // Vision's origin is bottom-left.
        return UnitPoint2D(x: Double(union.midX), y: 1 - Double(union.midY))
    }

    /// Detects panels and fills in each panel's content bounds.
    public static func analyse(_ image: CGImage, options: PanelDetector.Options = PanelDetector.Options()) -> (panels: [ComicPanel], paper: RGBAColor) {
        let detection = PanelDetector.detect(image, options: options)
        let panels = detection.panels.map { rect in
            ComicPanel(rect: rect, subject: contentBounds(in: image, panel: rect))
        }
        return (panels, detection.paper)
    }
}
