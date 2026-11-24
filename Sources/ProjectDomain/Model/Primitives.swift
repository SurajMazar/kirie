import Foundation

/// Current project schema. Bump when the JSON shape changes and add a migration.
public enum SchemaVersion {
    public static let current = 1
}

public struct RGBAColor: Hashable, Sendable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `#RRGGBB` or `#RRGGBBAA`. Invalid input yields nil rather than trapping.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let raw = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(r: Double((raw >> 16) & 0xFF) / 255, g: Double((raw >> 8) & 0xFF) / 255, b: Double(raw & 0xFF) / 255)
        } else {
            self.init(r: Double((raw >> 24) & 0xFF) / 255, g: Double((raw >> 16) & 0xFF) / 255,
                      b: Double((raw >> 8) & 0xFF) / 255, a: Double(raw & 0xFF) / 255)
        }
    }

    public var hex: String {
        func c(_ v: Double) -> Int { Int((Swift.max(0, Swift.min(1, v)) * 255).rounded()) }
        return a >= 0.999
            ? String(format: "#%02X%02X%02X", c(r), c(g), c(b))
            : String(format: "#%02X%02X%02X%02X", c(r), c(g), c(b), c(a))
    }

    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    /// Warm paper tone used as the Comic Studio default.
    public static let paper = RGBAColor(r: 0.957, g: 0.925, b: 0.859)
}

/// Point in normalised canvas space: (0,0) top-left, (1,1) bottom-right.
public struct UnitPoint2D: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let center = UnitPoint2D(x: 0.5, y: 0.5)
}

/// Rectangle in normalised space (top-left origin), used for crops and comic panels.
public struct UnitRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { width * height }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 && x >= -1e-9 && y >= -1e-9
            && maxX <= 1 + 1e-9 && maxY <= 1 + 1e-9
    }

    /// Clamps into the unit square, keeping a minimum size.
    public func clamped(minSize: Double = 0.01) -> UnitRect {
        let nx = Swift.max(0, Swift.min(1 - minSize, x.isFinite ? x : 0))
        let ny = Swift.max(0, Swift.min(1 - minSize, y.isFinite ? y : 0))
        let nw = Swift.max(minSize, Swift.min(1 - nx, width.isFinite ? width : 1))
        let nh = Swift.max(minSize, Swift.min(1 - ny, height.isFinite ? height : 1))
        return UnitRect(x: nx, y: ny, width: nw, height: nh)
    }

    public func contains(_ other: UnitRect, tolerance: Double = 1e-9) -> Bool {
        other.x >= x - tolerance && other.y >= y - tolerance && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }

    public func intersection(_ other: UnitRect) -> UnitRect? {
        let nx = Swift.max(x, other.x), ny = Swift.max(y, other.y)
        let mx = Swift.min(maxX, other.maxX), my = Swift.min(maxY, other.maxY)
        return mx > nx && my > ny ? UnitRect(x: nx, y: ny, width: mx - nx, height: my - ny) : nil
    }
}

public enum ColorSpaceTag: String, Sendable, Codable, CaseIterable {
    case rec709
    case displayP3
    case sRGB

    public var displayName: String {
        switch self {
        case .rec709: "Rec. 709 (SDR video)"
        case .displayP3: "Display P3"
        case .sRGB: "sRGB"
        }
    }
}

public struct CanvasSettings: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var colorSpace: ColorSpaceTag
    public var background: RGBAColor

    public init(width: Int, height: Int, frameRate: FrameRate = .fps30, colorSpace: ColorSpaceTag = .rec709,
                background: RGBAColor = .black) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.colorSpace = colorSpace
        self.background = background
    }

    public var aspectRatio: Double { height == 0 ? 1 : Double(width) / Double(height) }
}

public struct CanvasPreset: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let ratioLabel: String
    public let width: Int
    public let height: Int

    public static let all: [CanvasPreset] = [
        CanvasPreset(id: "vertical", name: "Vertical", ratioLabel: "9:16", width: 1080, height: 1920),
        CanvasPreset(id: "portrait", name: "Portrait", ratioLabel: "4:5", width: 1080, height: 1350),
        CanvasPreset(id: "square", name: "Square", ratioLabel: "1:1", width: 1080, height: 1080),
        CanvasPreset(id: "landscape", name: "Landscape", ratioLabel: "16:9", width: 1920, height: 1080),
        CanvasPreset(id: "cinema", name: "Cinema", ratioLabel: "21:9", width: 2560, height: 1080),
    ]

    public static func named(_ id: String) -> CanvasPreset? { all.first { $0.id == id } }
}
