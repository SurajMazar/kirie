import Foundation

public enum TextAlignment: String, Sendable, Codable, CaseIterable {
    case left, center, right
}

public struct TextShadow: Hashable, Sendable, Codable {
    public var color: RGBAColor
    public var blur: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(color: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6), blur: Double = 8, offsetX: Double = 0,
                offsetY: Double = 3) {
        self.color = color
        self.blur = blur
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

public struct TextBackground: Hashable, Sendable, Codable {
    public var color: RGBAColor
    public var padding: Double
    public var cornerRadius: Double

    public init(color: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6), padding: Double = 16, cornerRadius: Double = 12) {
        self.color = color
        self.padding = padding
        self.cornerRadius = cornerRadius
    }
}

/// Sizes are in canvas pixels at a 1080-wide reference canvas and scale with the canvas width.
public struct TextStyle: Hashable, Sendable, Codable {
    public var fontName: String
    public var fontSize: Double
    public var color: RGBAColor
    public var strokeColor: RGBAColor
    public var strokeWidth: Double
    public var shadow: TextShadow?
    public var background: TextBackground?
    public var alignment: TextAlignment
    public var lineSpacing: Double
    public var allCaps: Bool
    /// Maximum text block width as a fraction of the canvas width.
    public var maxWidth: Double
    /// Colour of the active word in karaoke captions.
    public var highlightColor: RGBAColor

    public init(fontName: String = "Helvetica Neue Bold", fontSize: Double = 72, color: RGBAColor = .white,
                strokeColor: RGBAColor = .black, strokeWidth: Double = 0, shadow: TextShadow? = TextShadow(),
                background: TextBackground? = nil, alignment: TextAlignment = .center, lineSpacing: Double = 4,
                allCaps: Bool = false, maxWidth: Double = 0.86,
                highlightColor: RGBAColor = RGBAColor(r: 1, g: 0.84, b: 0.2)) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.shadow = shadow
        self.background = background
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.allCaps = allCaps
        self.maxWidth = maxWidth
        self.highlightColor = highlightColor
    }

    public static let title = TextStyle()
    public static let caption = TextStyle(fontSize: 54, strokeWidth: 6, shadow: nil)
}

public enum TextAnimation: String, Sendable, Codable, CaseIterable {
    case none, fade, typewriter, pop, bounce, karaoke

    public var displayName: String {
        switch self {
        case .none: "None"
        case .fade: "Fade"
        case .typewriter: "Typewriter"
        case .pop: "Pop"
        case .bounce: "Bounce"
        case .karaoke: "Karaoke highlight"
        }
    }
}

public enum TextRole: String, Sendable, Codable {
    case title, caption, lyric
}

/// A word with its own timing, relative to the owning clip's start.
public struct TimedWord: Hashable, Sendable, Codable {
    public var text: String
    public var start: RationalTime
    public var end: RationalTime

    public init(text: String, start: RationalTime, end: RationalTime) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TextContent: Hashable, Sendable, Codable {
    public var string: String
    public var role: TextRole
    public var style: TextStyle
    public var animation: TextAnimation
    /// Word-level timing for karaoke captions (optional).
    public var words: [TimedWord]
    /// Lyric-mode presentation (role == .lyric).
    public var lyric: LyricPresentation?

    public init(string: String, role: TextRole = .title, style: TextStyle = .title, animation: TextAnimation = .none,
                words: [TimedWord] = [], lyric: LyricPresentation? = nil) {
        self.string = string
        self.role = role
        self.style = style
        self.animation = animation
        self.words = words
        self.lyric = lyric
    }
}

public enum LyricStyle: String, Sendable, Codable, CaseIterable {
    /// Hand-lettered rows that type on.
    case verse
    /// Zig-zag rows whose words rise into place.
    case stack
    /// Bold caps that slam in.
    case chorus
    /// Left-aligned stack with one big word.
    case block

    public var displayName: String {
        switch self {
        case .verse: "Verse"
        case .stack: "Stack"
        case .chorus: "Chorus"
        case .block: "Block"
        }
    }
}

/// How a lyric line is lettered. Word times are relative to the clip start.
public struct LyricPresentation: Hashable, Sendable, Codable {
    public var style: LyricStyle
    /// Reveal time of each word, in reading order.
    public var wordTimes: [RationalTime]
    /// Vertical centre of the lettering block, normalised (0 = top).
    public var verticalPosition: Double
    /// Small per-letter jitter on the lettering only; the picture never wobbles.
    public var letterJitter: Bool
    /// Crayon-style colour stripe behind the lettering.
    public var stripe: RGBAColor?
    /// White flash on the line's first frame (chorus hits).
    public var flashOnHit: Bool

    public init(style: LyricStyle = .verse, wordTimes: [RationalTime] = [], verticalPosition: Double = 0.18,
                letterJitter: Bool = false, stripe: RGBAColor? = nil, flashOnHit: Bool = false) {
        self.style = style
        self.wordTimes = wordTimes
        self.verticalPosition = verticalPosition
        self.letterJitter = letterJitter
        self.stripe = stripe
        self.flashOnHit = flashOnHit
    }
}
