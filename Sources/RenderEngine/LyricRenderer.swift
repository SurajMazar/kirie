import CoreImage
import Foundation
import ProjectDomain

/// Word-by-word lettering for lyric edits. The picture underneath is never moved by this layer.
enum LyricRenderer {
    struct Style {
        var emphasisScale: CGFloat
        var emphasisFont: String?
        var lineHeight: CGFloat
    }

    static func parameters(for style: LyricStyle) -> Style {
        switch style {
        case .verse: Style(emphasisScale: 1.45, emphasisFont: "Marker Felt Wide", lineHeight: 1.0)
        case .stack: Style(emphasisScale: 1.5, emphasisFont: nil, lineHeight: 0.92)
        case .chorus: Style(emphasisScale: 1.3, emphasisFont: nil, lineHeight: 0.9)
        case .block: Style(emphasisScale: 1.9, emphasisFont: nil, lineHeight: 0.88)
        }
    }

    struct Placed {
        let rendered: TextRasterizer.Rendered
        /// Bottom-left of the glyph box (not the padded bitmap) in output coordinates.
        let origin: CGPoint
        let size: CGSize
        let emphasised: Bool
        let index: Int
    }

    static func layout(text: TextContent, lyric: LyricPresentation, canvas: CGRect, scale: CGFloat) -> (words: [Placed], bounds: CGRect) {
        var rows = LyricMarkup.parse(text.string)
        if lyric.style == .block { rows = LyricMarkup.applyingBlockDefault(rows) }
        let parameters = parameters(for: lyric.style)
        let style = text.style
        let baseSize = CGFloat(style.fontSize) * scale
        let stroke = CGFloat(style.strokeWidth) * scale
        let maxWidth = canvas.width * CGFloat(style.maxWidth)

        struct Measured { var rendered: TextRasterizer.Rendered; var emphasised: Bool; var index: Int }
        func measure(fit: CGFloat) -> [[Measured]] {
            var index = 0
            return rows.rows.map { row in
                row.compactMap { token in
                    defer { index += 1 }
                    let display = style.allCaps ? token.text.uppercased() : token.text
                    let size = baseSize * (token.emphasised ? parameters.emphasisScale : 1) * fit
                    let font = token.emphasised ? (parameters.emphasisFont ?? style.fontName) : style.fontName
                    let color = token.emphasised ? style.highlightColor : style.color
                    guard let rendered = TextRasterizer.shared.word(display, fontName: font, fontSize: size, color: color,
                                                                   strokeColor: style.strokeColor, strokeWidth: stroke * fit,
                                                                   shadow: style.shadow, scale: scale) else { return nil }
                    return Measured(rendered: rendered, emphasised: token.emphasised, index: index)
                }
            }
        }
        func rowWidth(_ row: [Measured], gap: CGFloat) -> CGFloat {
            row.reduce(0) { $0 + $1.rendered.advance } + gap * CGFloat(max(0, row.count - 1))
        }

        // Shrink to fit: every row must stay inside the lettering width.
        var fit: CGFloat = 1
        var measured = measure(fit: fit)
        let widest = measured.map { rowWidth($0, gap: baseSize * 0.26) }.max() ?? 0
        if widest > maxWidth, widest > 0 {
            fit = max(0.3, maxWidth / widest)
            measured = measure(fit: fit)
        }
        let gap = baseSize * 0.26 * fit
        let spacing = CGFloat(style.lineSpacing) * scale * fit
        let heights = measured.map { row in (row.map { $0.rendered.ascent + $0.rendered.descent }.max() ?? 0) * parameters.lineHeight }
        let totalHeight = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        let centerY = canvas.maxY - canvas.height * CGFloat(lyric.verticalPosition)
        var top = centerY + totalHeight / 2
        let left = canvas.minX + (canvas.width - maxWidth) / 2

        var placed: [Placed] = []
        var bounds = CGRect.null
        for (rowIndex, row) in measured.enumerated() {
            let width = rowWidth(row, gap: gap)
            let ascent = row.map { $0.rendered.ascent }.max() ?? 0
            // All words of a row share one baseline, whatever their size.
            let baseline = top - ascent * parameters.lineHeight
            var x: CGFloat
            switch lyric.style {
            case .verse, .chorus: x = canvas.midX - width / 2
            case .stack: x = rowIndex % 2 == 0 ? left : left + maxWidth - width
            case .block: x = left
            }
            for word in row {
                let size = CGSize(width: word.rendered.advance, height: word.rendered.ascent + word.rendered.descent)
                let origin = CGPoint(x: x, y: baseline - word.rendered.descent)
                placed.append(Placed(rendered: word.rendered, origin: origin, size: size, emphasised: word.emphasised, index: word.index))
                bounds = bounds.union(CGRect(origin: origin, size: size))
                x += word.rendered.advance + gap
            }
            top -= heights[rowIndex] + spacing
        }
        return (placed, bounds)
    }

    /// The lettering layer for one lyric clip at `local` seconds after the clip starts.
    static func layer(clip: Clip, local: Double, canvas: CGRect, scale: CGFloat, frame: Int64) -> CIImage {
        guard let text = clip.text, let lyric = text.lyric else { return CIImage.empty() }
        let (words, bounds) = layout(text: text, lyric: lyric, canvas: canvas, scale: scale)
        guard !words.isEmpty else { return CIImage.empty() }
        let duration = clip.duration.seconds
        var times = lyric.wordTimes.map(\.seconds)
        if times.count != words.count {
            times = WordTiming.distribute(wordCount: words.count, start: .zero, end: clip.duration, hold: 0.4).map(\.seconds)
        }
        // The whole line fades out over its last moments.
        let exit = max(0, min(1, (duration - local) / 0.12))
        var output = CIImage.empty()

        if let stripe = lyric.stripe, !bounds.isNull {
            let pad = 18 * scale
            let appear = max(0, min(1, (local - (times.first ?? 0)) / 0.15))
            var band = CIImage(color: CIColor(red: stripe.r, green: stripe.g, blue: stripe.b, alpha: stripe.a * 0.92 * appear * exit))
                .cropped(to: bounds.insetBy(dx: -pad * 1.4, dy: -pad))
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            band = band.transformed(by: CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -0.02).translatedBy(x: -center.x, y: -center.y))
            output = band
        }

        for word in words {
            let age = local - times[word.index]
            guard age >= 0 else { continue }
            var alpha = exit
            var scaleFactor: CGFloat = 1
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch lyric.style {
            case .verse:
                let t = min(1, age / 0.12)
                alpha *= t
                scaleFactor = 0.9 + 0.1 * CGFloat(Easing.easeOut.apply(t))
            case .stack:
                let t = min(1, age / 0.18)
                alpha *= t
                dy = -28 * scale * CGFloat(1 - Easing.easeOut.apply(t))
            case .chorus:
                let t = min(1, age / 0.12)
                alpha *= min(1, t * 2)
                scaleFactor = 1.6 - 0.6 * CGFloat(Easing.easeOut.apply(t))
            case .block:
                let t = min(1, age / 0.15)
                alpha *= t
                dx = -40 * scale * CGFloat(1 - Easing.easeOut.apply(t))
                if word.emphasised { scaleFactor = 1.25 - 0.25 * CGFloat(Easing.back.apply(t)) }
            }
            if word.emphasised, age > 0.15 {
                // Emphasis keeps a gentle pulse.
                scaleFactor *= 1 + 0.035 * CGFloat(sin(age * 2 * .pi * 2))
            }
            if lyric.letterJitter {
                // Hand-lettered wobble: lettering only, changing a few times a second.
                dx += CGFloat(Transitions.noise(frame / 4, Int64(word.index) * 2) - 0.5) * 3.2 * scale
                dy += CGFloat(Transitions.noise(frame / 4, Int64(word.index) * 2 + 1) - 0.5) * 3.2 * scale
            }
            let pad = word.rendered.padding
            let center = CGPoint(x: word.origin.x + word.size.width / 2 + dx, y: word.origin.y + word.size.height / 2 + dy)
            let bitmap = word.rendered.image.extent
            var transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: scaleFactor, y: scaleFactor)
            transform = transform.translatedBy(x: -(pad + word.size.width / 2), y: -(pad + word.size.height / 2))
            _ = bitmap
            let image = LayerEffects.opacity(alpha, word.rendered.image.transformed(by: transform))
            output = image.composited(over: output)
        }
        if lyric.flashOnHit, local < 0.12 {
            let flash = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.75 * (1 - local / 0.12))).cropped(to: canvas)
            output = output.composited(over: flash)
        }
        return output.cropped(to: canvas)
    }
}
