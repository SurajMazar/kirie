import Foundation

public enum ClipKind: String, Sendable, Codable {
    case video, image, audio, text, solid
}

public enum FitMode: String, Sendable, Codable, CaseIterable {
    /// Whole picture visible; letterboxed if aspect ratios differ.
    case contain
    /// Canvas filled; picture cropped if aspect ratios differ.
    case cover
    /// Stretched to the canvas.
    case fill
}

public enum BlendMode: String, Sendable, Codable, CaseIterable {
    case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten, colorDodge, colorBurn, difference
}

/// What sits behind a clip that does not fill the canvas.
public enum ClipBackdrop: String, Sendable, Codable, CaseIterable {
    case none
    /// A blurred, canvas-filling copy of the same picture.
    case blur
    /// A flat colour (`ClipTransform.backdropColor`), for example a comic's paper tone.
    case color
}

public struct ClipTransform: Hashable, Sendable, Codable {
    /// Centre of the clip in normalised canvas space.
    public var position: UnitPoint2D
    public var scale: Double
    /// Degrees, clockwise.
    public var rotation: Double
    public var opacity: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Region of the source picture to show, normalised with a top-left origin.
    public var crop: UnitRect
    public var fit: FitMode
    public var backdrop: ClipBackdrop
    public var backdropColor: RGBAColor?

    public init(position: UnitPoint2D = .center, scale: Double = 1, rotation: Double = 0, opacity: Double = 1,
                flipHorizontal: Bool = false, flipVertical: Bool = false, crop: UnitRect = .full,
                fit: FitMode = .contain, backdrop: ClipBackdrop = .none, backdropColor: RGBAColor? = nil) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.crop = crop
        self.fit = fit
        self.backdrop = backdrop
        self.backdropColor = backdropColor
    }

    public static let identity = ClipTransform()
}

public enum AnimatableProperty: String, Sendable, Codable, CaseIterable {
    case positionX, positionY, scale, rotation, opacity, volume

    public var displayName: String {
        switch self {
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .volume: "Volume"
        }
    }
}

public enum Easing: String, Sendable, Codable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut, hold, back, bounce

    /// Maps linear progress 0…1 to eased progress.
    public func apply(_ t: Double) -> Double {
        let x = Swift.max(0, Swift.min(1, t))
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .hold: return x >= 1 ? 1 : 0
        case .back:
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
        case .bounce:
            let n1 = 7.5625, d1 = 2.75
            var v = x
            if v < 1 / d1 { return n1 * v * v }
            if v < 2 / d1 { v -= 1.5 / d1; return n1 * v * v + 0.75 }
            if v < 2.5 / d1 { v -= 2.25 / d1; return n1 * v * v + 0.9375 }
            v -= 2.625 / d1
            return n1 * v * v + 0.984375
        }
    }
}

public struct Keyframe: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var property: AnimatableProperty
    /// Time relative to the clip's start.
    public var time: RationalTime
    public var value: Double
    /// Easing applied on the way *to* this keyframe.
    public var easing: Easing

    public init(id: UUID = UUID(), property: AnimatableProperty, time: RationalTime, value: Double,
                easing: Easing = .easeInOut) {
        self.id = id
        self.property = property
        self.time = time
        self.value = value
        self.easing = easing
    }
}

public enum TransitionType: String, Sendable, Codable, CaseIterable {
    case dissolve, dipToBlack, dipToWhite, push, slide, wipe, zoom, iris, whip, spin, glitch
    case pageFold, polaroidDrop, inkSplash, panelSlide

    public var displayName: String {
        switch self {
        case .dissolve: "Dissolve"
        case .dipToBlack: "Dip to black"
        case .dipToWhite: "Flash"
        case .push: "Push"
        case .slide: "Slide"
        case .wipe: "Soft wipe"
        case .zoom: "Zoom"
        case .iris: "Iris"
        case .whip: "Whip"
        case .spin: "Spin"
        case .glitch: "Glitch"
        case .pageFold: "Page fold"
        case .polaroidDrop: "Polaroid drop"
        case .inkSplash: "Ink splash"
        case .panelSlide: "Panel slide"
        }
    }

    public var isComic: Bool { [.pageFold, .polaroidDrop, .inkSplash, .panelSlide].contains(self) }
    public var usesDirection: Bool { [.push, .slide, .wipe, .whip, .pageFold, .panelSlide].contains(self) }

    /// What to render instead when Reduce Motion is on.
    public var reducedMotionAlternative: TransitionType {
        switch self {
        case .dissolve, .dipToBlack: self
        case .dipToWhite: .dissolve
        default: .dissolve
        }
    }
}

public enum Direction: String, Sendable, Codable, CaseIterable {
    case left, right, up, down
}

public struct Transition: Hashable, Sendable, Codable {
    public var type: TransitionType
    public var duration: RationalTime
    public var direction: Direction

    public init(type: TransitionType, duration: RationalTime = RationalTime(seconds: 0.45), direction: Direction = .left) {
        self.type = type
        self.duration = duration
        self.direction = direction
    }
}

public struct ClipAudio: Hashable, Sendable, Codable {
    /// Linear gain, 0…4 (1 = unity).
    public var gain: Double
    public var muted: Bool
    public var fadeIn: RationalTime
    public var fadeOut: RationalTime

    public init(gain: Double = 1, muted: Bool = false, fadeIn: RationalTime = .zero, fadeOut: RationalTime = .zero) {
        self.gain = gain
        self.muted = muted
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }
}

public struct ColorAdjust: Hashable, Sendable, Codable {
    /// EV, -2…2.
    public var exposure: Double
    /// -1…1 around neutral.
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var saturation: Double
    public var temperature: Double
    public var tint: Double
    /// 0…1.
    public var vignette: Double
    public var sharpen: Double

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
                saturation: Double = 0, temperature: Double = 0, tint: Double = 0, vignette: Double = 0,
                sharpen: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.vignette = vignette
        self.sharpen = sharpen
    }

    public static let neutral = ColorAdjust()
    public var isNeutral: Bool { self == .neutral }
}

public enum FilterKind: String, Sendable, Codable, CaseIterable {
    case mono, noir, fade, chrome, instant, process, tonal, transfer, sepia, vivid, warm, cool
    case blur, pixellate, bloom, halftone, inkOutline, posterize, vhs, grain

    public var displayName: String {
        switch self {
        case .mono: "Mono"
        case .noir: "Noir"
        case .fade: "Fade"
        case .chrome: "Chrome"
        case .instant: "Instant"
        case .process: "Process"
        case .tonal: "Tonal"
        case .transfer: "Transfer"
        case .sepia: "Sepia"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .blur: "Blur"
        case .pixellate: "Pixellate"
        case .bloom: "Bloom"
        case .halftone: "Halftone"
        case .inkOutline: "Ink outline"
        case .posterize: "Posterize"
        case .vhs: "VHS"
        case .grain: "Paper grain"
        }
    }

    public var isLook: Bool {
        [.mono, .noir, .fade, .chrome, .instant, .process, .tonal, .transfer, .sepia, .vivid, .warm, .cool].contains(self)
    }
}

public struct AppliedFilter: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var kind: FilterKind
    /// 0…1.
    public var intensity: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), kind: FilterKind, intensity: Double = 1, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.intensity = intensity
        self.enabled = enabled
    }
}

public enum MaskShape: String, Sendable, Codable, CaseIterable {
    case rectangle, ellipse, linear, mirror
}

public struct ClipMask: Hashable, Sendable, Codable {
    public var shape: MaskShape
    /// Mask bounds in the clip's own normalised space.
    public var rect: UnitRect
    /// 0…1 softness.
    public var feather: Double
    public var inverted: Bool

    public init(shape: MaskShape = .ellipse, rect: UnitRect = UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                feather: Double = 0.05, inverted: Bool = false) {
        self.shape = shape
        self.rect = rect
        self.feather = feather
        self.inverted = inverted
    }
}

public struct ChromaKey: Hashable, Sendable, Codable {
    public var color: RGBAColor
    /// Hue tolerance 0…1.
    public var tolerance: Double
    public var softness: Double

    public init(color: RGBAColor = RGBAColor(r: 0, g: 1, b: 0), tolerance: Double = 0.18, softness: Double = 0.08) {
        self.color = color
        self.tolerance = tolerance
        self.softness = softness
    }
}

/// One item on a track. Value type; all timing is rational.
public struct Clip: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var kind: ClipKind
    public var assetID: UUID?
    public var name: String
    /// Position on the timeline.
    public var start: RationalTime
    /// Length on the timeline.
    public var duration: RationalTime
    /// Offset into the source media.
    public var sourceStart: RationalTime
    /// Playback rate (1 = normal). Source time consumed = duration × speed.
    public var speed: Double
    public var transform: ClipTransform
    public var keyframes: [Keyframe]
    /// Transition from the previous clip into this one (main track), or an entrance (free tracks).
    public var transitionIn: Transition?
    public var audio: ClipAudio
    public var color: ColorAdjust
    public var filters: [AppliedFilter]
    public var blendMode: BlendMode
    public var mask: ClipMask?
    public var chromaKey: ChromaKey?
    public var text: TextContent?
    public var solidColor: RGBAColor?
    /// Audio/video link created by Detach Audio. Linked clips ripple together.
    public var linkedClipID: UUID?

    public init(id: UUID = UUID(), kind: ClipKind, assetID: UUID? = nil, name: String = "", start: RationalTime = .zero,
                duration: RationalTime, sourceStart: RationalTime = .zero, speed: Double = 1,
                transform: ClipTransform = .identity, keyframes: [Keyframe] = [], transitionIn: Transition? = nil,
                audio: ClipAudio = ClipAudio(), color: ColorAdjust = .neutral, filters: [AppliedFilter] = [],
                blendMode: BlendMode = .normal, mask: ClipMask? = nil, chromaKey: ChromaKey? = nil,
                text: TextContent? = nil, solidColor: RGBAColor? = nil, linkedClipID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.assetID = assetID
        self.name = name
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.speed = speed
        self.transform = transform
        self.keyframes = keyframes
        self.transitionIn = transitionIn
        self.audio = audio
        self.color = color
        self.filters = filters
        self.blendMode = blendMode
        self.mask = mask
        self.chromaKey = chromaKey
        self.text = text
        self.solidColor = solidColor
        self.linkedClipID = linkedClipID
    }

    public var end: RationalTime { start + duration }
    public var range: TimeRange { TimeRange(start: start, duration: duration) }
    /// Source media consumed by this clip.
    public var sourceDuration: RationalTime { speed == 1 ? duration : duration.scaled(by: speed) }
    public var sourceEnd: RationalTime { sourceStart + sourceDuration }
    public var isVisual: Bool { kind != .audio }
    public var usesSourceTiming: Bool { kind == .video || kind == .audio }

    /// Base (un-keyframed) value of a property.
    public func baseValue(_ property: AnimatableProperty) -> Double {
        switch property {
        case .positionX: transform.position.x
        case .positionY: transform.position.y
        case .scale: transform.scale
        case .rotation: transform.rotation
        case .opacity: transform.opacity
        case .volume: audio.gain
        }
    }

    /// Keyframed value at a time relative to the clip start.
    public func value(of property: AnimatableProperty, at localTime: RationalTime) -> Double {
        let frames = keyframes.filter { $0.property == property }.sorted { $0.time < $1.time }
        guard let first = frames.first, let last = frames.last else { return baseValue(property) }
        if localTime <= first.time { return first.value }
        if localTime >= last.time { return last.value }
        for index in 1..<frames.count where localTime <= frames[index].time {
            let a = frames[index - 1], b = frames[index]
            let span = (b.time - a.time).seconds
            guard span > 0 else { return b.value }
            let t = (localTime - a.time).seconds / span
            return a.value + (b.value - a.value) * b.easing.apply(t)
        }
        return last.value
    }

    public func hasKeyframes(for property: AnimatableProperty) -> Bool {
        keyframes.contains { $0.property == property }
    }
}
