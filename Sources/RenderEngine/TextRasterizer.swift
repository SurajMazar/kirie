import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ProjectDomain

/// Draws text with Core Text into cached bitmaps. Layout happens once per distinct request; the
/// compositor then only moves, scales and fades the cached image on the GPU.
final class TextRasterizer: @unchecked Sendable {
    static let shared = TextRasterizer()

    final class Rendered {
        let image: CIImage
        /// Padding around the text block inside the bitmap (room for stroke and shadow).
        let padding: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        /// Typographic advance of a single-line render.
        let advance: CGFloat
        init(image: CIImage, padding: CGFloat, ascent: CGFloat, descent: CGFloat, advance: CGFloat) {
            self.image = image
            self.padding = padding
            self.ascent = ascent
            self.descent = descent
            self.advance = advance
        }
    }

    private let cache = NSCache<NSString, Rendered>()

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    static func displayString(_ content: TextContent) -> String {
        content.style.allCaps ? content.string.uppercased() : content.string
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func key(_ parts: [String]) -> NSString { parts.joined(separator: "\u{1F}") as NSString }

    private func styleKey(_ style: TextStyle) -> String {
        "\(style.fontName)|\(style.fontSize)|\(style.color.hex)|\(style.strokeColor.hex)|\(style.strokeWidth)|\(style.alignment.rawValue)|\(style.lineSpacing)|"
            + "\(style.shadow.map { "\($0.color.hex),\($0.blur),\($0.offsetX),\($0.offsetY)" } ?? "-")|"
            + "\(style.background.map { "\($0.color.hex),\($0.padding),\($0.cornerRadius)" } ?? "-")|\(style.highlightColor.hex)"
    }

    private static func attributes(font: CTFont, color: CGColor, paragraph: CTParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if let paragraph { attributes[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = paragraph }
        return attributes
    }

    private static func paragraph(_ style: TextStyle, scale: CGFloat) -> CTParagraphStyle {
        var alignment: CTTextAlignment = switch style.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var spacing = CGFloat(style.lineSpacing) * scale
        return withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &spacing) { spacingBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: spacingBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    /// A multi-line text block.
    ///
    /// - `highlight`: character range drawn in the style's highlight colour (karaoke).
    /// - `visibleCharacters`: characters beyond this count are laid out but invisible (typewriter).
    func block(_ string: String, style: TextStyle, scale: CGFloat, maxWidth: CGFloat, highlight: Range<Int>? = nil,
               visibleCharacters: Int? = nil) -> Rendered? {
        guard !string.isEmpty, scale > 0, maxWidth > 4 else { return nil }
        let cacheKey = key(["block", string, styleKey(style), "\(scale)", "\(maxWidth)",
                            highlight.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "-", visibleCharacters.map(String.init) ?? "-"])
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let fontSize = max(1, CGFloat(style.fontSize) * scale)
        let font = CTFontCreateWithName(style.fontName as CFString, fontSize, nil)
        let paragraph = TextRasterizer.paragraph(style, scale: scale)
        let characters = Array(string)

        func utf16Range(_ range: Range<Int>) -> NSRange {
            let lower = max(0, min(characters.count, range.lowerBound)), upper = max(lower, min(characters.count, range.upperBound))
            let start = String(characters[..<lower]).utf16.count
            return NSRange(location: start, length: String(characters[lower..<upper]).utf16.count)
        }
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        let hidden: NSRange? = visibleCharacters.map { utf16Range(max(0, $0)..<characters.count) }

        let fill = NSMutableAttributedString(string: string, attributes: TextRasterizer.attributes(font: font, color: style.color.cgColor, paragraph: paragraph))
        if let highlight {
            fill.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: style.highlightColor.cgColor, range: utf16Range(highlight))
        }
        if let hidden, hidden.length > 0 {
            fill.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: clear, range: hidden)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(fill)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                     CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(suggested.width) + 2, height: ceil(suggested.height) + 2)
        let stroke = CGFloat(style.strokeWidth) * scale
        let shadowReach = style.shadow.map { CGFloat($0.blur + max(abs($0.offsetX), abs($0.offsetY))) * scale } ?? 0
        let boxPadding = style.background.map { CGFloat($0.padding) * scale } ?? 0
        let padding = ceil(stroke + shadowReach + boxPadding + 4)
        let width = Int(textSize.width + padding * 2), height = Int(textSize.height + padding * 2)
        guard let context = makeContext(width: width, height: height) else { return nil }
        let textRect = CGRect(x: padding, y: padding, width: textSize.width, height: textSize.height)

        if let background = style.background {
            let box = textRect.insetBy(dx: -boxPadding, dy: -boxPadding)
            let radius = min(CGFloat(background.cornerRadius) * scale, min(box.width, box.height) / 2)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(background.color.cgColor)
            context.fillPath()
        }

        func draw(_ attributed: NSAttributedString) {
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, context)
        }

        context.setLineJoin(.round)
        if let shadow = style.shadow {
            context.setShadow(offset: CGSize(width: CGFloat(shadow.offsetX) * scale, height: -CGFloat(shadow.offsetY) * scale),
                              blur: CGFloat(shadow.blur) * scale, color: shadow.color.cgColor)
        }
        if stroke > 0 {
            // Outline pass: a stroke twice the wanted thickness, so the visible outer half matches it.
            let outline = NSMutableAttributedString(attributedString: fill)
            let whole = NSRange(location: 0, length: outline.length)
            outline.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: stroke * 2 / fontSize * 100, range: whole)
            outline.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: style.strokeColor.cgColor, range: whole)
            if let hidden, hidden.length > 0 {
                outline.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: clear, range: hidden)
            }
            draw(outline)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        draw(fill)
        guard let image = context.makeImage() else { return nil }
        let rendered = Rendered(image: CIImage(cgImage: image), padding: padding, ascent: 0, descent: 0, advance: textSize.width)
        cache.setObject(rendered, forKey: cacheKey, cost: width * height * 4)
        return rendered
    }

    /// A single word on one line, for word-by-word lettering.
    func word(_ string: String, fontName: String, fontSize: CGFloat, color: RGBAColor, strokeColor: RGBAColor, strokeWidth: CGFloat,
              shadow: TextShadow?, scale: CGFloat) -> Rendered? {
        guard !string.isEmpty, fontSize > 0 else { return nil }
        let cacheKey = key(["word", string, fontName, "\(fontSize)", color.hex, strokeColor.hex, "\(strokeWidth)",
                            shadow.map { "\($0.color.hex),\($0.blur)" } ?? "-", "\(scale)"])
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let fill = NSAttributedString(string: string, attributes: TextRasterizer.attributes(font: font, color: color.cgColor))
        let line = CTLineCreateWithAttributedString(fill)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let shadowReach = shadow.map { CGFloat($0.blur) * scale } ?? 0
        let padding = ceil(strokeWidth + shadowReach + 4)
        let width = Int(ceil(advance) + padding * 2), height = Int(ceil(ascent + descent) + padding * 2)
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.setLineJoin(.round)
        let origin = CGPoint(x: padding, y: padding + descent)
        if let shadow {
            context.setShadow(offset: CGSize(width: CGFloat(shadow.offsetX) * scale, height: -CGFloat(shadow.offsetY) * scale),
                              blur: CGFloat(shadow.blur) * scale, color: shadow.color.cgColor)
        }
        if strokeWidth > 0 {
            var attributes = TextRasterizer.attributes(font: font, color: color.cgColor)
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth * 2 / fontSize * 100
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor.cgColor
            context.textPosition = origin
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), context)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        context.textPosition = origin
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        let rendered = Rendered(image: CIImage(cgImage: image), padding: padding, ascent: ascent, descent: descent, advance: advance)
        cache.setObject(rendered, forKey: cacheKey, cost: width * height * 4)
        return rendered
    }
}
