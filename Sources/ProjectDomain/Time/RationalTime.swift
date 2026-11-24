import Foundation

/// Exact rational time. The authoritative representation for every timeline value.
///
/// Stored reduced (`value / timescale` in lowest terms, positive timescale) so equality is structural.
/// Encodes to JSON as the string `"value/timescale"`, which keeps project files diff-friendly.
public struct RationalTime: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: Int64
    public let timescale: Int64

    public static let zero = RationalTime(unchecked: 0, 1)
    /// Divisible by every common frame rate including the NTSC family (1001 based).
    public static let defaultTimescale: Int64 = 120_000

    private init(unchecked value: Int64, _ timescale: Int64) {
        self.value = value
        self.timescale = timescale
    }

    /// Creates a reduced rational. A zero timescale is treated as 1 so malformed input can never trap.
    public init(_ value: Int64, _ timescale: Int64) {
        var v = value
        var t = timescale == 0 ? 1 : timescale
        if t < 0 { v = -v; t = -t }
        let g = RationalTime.gcd(v.magnitude, t.magnitude)
        if g > 1 {
            v /= Int64(g)
            t /= Int64(g)
        }
        self.value = v
        self.timescale = t
    }

    public init(seconds: Double, timescale: Int64 = RationalTime.defaultTimescale) {
        let safe = seconds.isFinite ? seconds : 0
        let scaled = (safe * Double(timescale)).rounded()
        let clamped = Swift.max(Swift.min(scaled, 9.0e18), -9.0e18)
        self.init(Int64(clamped), timescale)
    }

    public init(frames: Int64, rate: FrameRate) {
        self.init(frames * rate.denominator, rate.numerator)
    }

    public var seconds: Double { Double(value) / Double(timescale) }
    public var isZero: Bool { value == 0 }
    public var isPositive: Bool { value > 0 }
    public var isNegative: Bool { value < 0 }

    public var description: String { "\(value)/\(timescale)" }

    // MARK: Arithmetic

    public static func + (a: RationalTime, b: RationalTime) -> RationalTime {
        if a.timescale == b.timescale {
            let (sum, overflow) = a.value.addingReportingOverflow(b.value)
            if !overflow { return RationalTime(sum, a.timescale) }
        }
        let g = Int64(gcd(a.timescale.magnitude, b.timescale.magnitude))
        let (l, o1) = (a.timescale / g).multipliedReportingOverflow(by: b.timescale)
        let (x, o2) = a.value.multipliedReportingOverflow(by: b.timescale / g)
        let (y, o3) = b.value.multipliedReportingOverflow(by: a.timescale / g)
        let (sum, o4) = x.addingReportingOverflow(y)
        if o1 || o2 || o3 || o4 {
            // Astronomically large operands: fall back to a rounded value on the default timescale.
            return RationalTime(seconds: a.seconds + b.seconds)
        }
        return RationalTime(sum, l)
    }

    public static prefix func - (a: RationalTime) -> RationalTime { RationalTime(-a.value, a.timescale) }
    public static func - (a: RationalTime, b: RationalTime) -> RationalTime { a + (-b) }
    public static func += (a: inout RationalTime, b: RationalTime) { a = a + b }
    public static func -= (a: inout RationalTime, b: RationalTime) { a = a - b }

    public static func * (a: RationalTime, n: Int64) -> RationalTime {
        let (v, overflow) = a.value.multipliedReportingOverflow(by: n)
        return overflow ? RationalTime(seconds: a.seconds * Double(n)) : RationalTime(v, a.timescale)
    }

    /// Scales by a floating-point factor (used for playback speed). The result is rounded to
    /// `timescale` ticks, so callers that need frame accuracy should quantise afterwards.
    public func scaled(by factor: Double, timescale: Int64 = RationalTime.defaultTimescale) -> RationalTime {
        RationalTime(seconds: seconds * factor, timescale: timescale)
    }

    public static func < (a: RationalTime, b: RationalTime) -> Bool {
        if a.timescale == b.timescale { return a.value < b.value }
        // Exact cross-multiplication in 128 bits.
        let l = a.value.multipliedFullWidth(by: b.timescale)
        let r = b.value.multipliedFullWidth(by: a.timescale)
        return l.high != r.high ? l.high < r.high : l.low < r.low
    }

    public static func min(_ a: RationalTime, _ b: RationalTime) -> RationalTime { a < b ? a : b }
    public static func max(_ a: RationalTime, _ b: RationalTime) -> RationalTime { a < b ? b : a }

    public func clamped(_ lower: RationalTime, _ upper: RationalTime) -> RationalTime {
        RationalTime.min(RationalTime.max(self, lower), upper)
    }

    // MARK: Frames

    /// Index of the frame containing this time (floor).
    public func frameIndex(rate: FrameRate) -> Int64 {
        let (num, o1) = value.multipliedReportingOverflow(by: rate.numerator)
        let (den, o2) = timescale.multipliedReportingOverflow(by: rate.denominator)
        if !o1, !o2, den != 0 { return floorDiv(num, den) }
        return Int64((seconds * rate.fps).rounded(.down))
    }

    /// Nearest frame boundary (ties round up).
    public func rounded(toFrame rate: FrameRate) -> RationalTime {
        let (num, o1) = value.multipliedReportingOverflow(by: rate.numerator)
        let (den, o2) = timescale.multipliedReportingOverflow(by: rate.denominator)
        let (twice, o3) = num.multipliedReportingOverflow(by: 2)
        if !o1, !o2, !o3, den != 0, den < Int64.max / 2 {
            return RationalTime(frames: floorDiv(twice + den, den * 2), rate: rate)
        }
        return RationalTime(frames: Int64((seconds * rate.fps).rounded()), rate: rate)
    }

    /// Frame boundary at or before this time.
    public func floored(toFrame rate: FrameRate) -> RationalTime {
        RationalTime(frames: frameIndex(rate: rate), rate: rate)
    }

    private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }
}

extension RationalTime: Codable {
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            guard let parsed = RationalTime(string: text) else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Invalid rational time '\(text)'")
            }
            self = parsed
        } else if let seconds = try? single.decode(Double.self) {
            guard seconds.isFinite else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Non-finite time")
            }
            self.init(seconds: seconds)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Expected \"value/timescale\" or seconds")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(description)
    }

    /// Parses `"value/timescale"`, or a plain decimal number of seconds.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let v = Int64(parts[0]), let t = Int64(parts[1]), t != 0 {
            self.init(v, t)
        } else if parts.count == 1, let s = Double(trimmed), s.isFinite {
            self.init(seconds: s)
        } else {
            return nil
        }
    }
}

/// A frame rate as an exact fraction (30000/1001 for 29.97).
public struct FrameRate: Hashable, Sendable, Codable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public init(_ numerator: Int64, _ denominator: Int64 = 1) {
        self.numerator = Swift.max(1, numerator)
        self.denominator = Swift.max(1, denominator)
    }

    public var fps: Double { Double(numerator) / Double(denominator) }
    public var frameDuration: RationalTime { RationalTime(denominator, numerator) }
    public var description: String {
        denominator == 1 ? "\(numerator)" : String(format: "%.3f", fps)
    }

    public static let fps24 = FrameRate(24)
    public static let fps25 = FrameRate(25)
    public static let fps30 = FrameRate(30)
    public static let fps50 = FrameRate(50)
    public static let fps60 = FrameRate(60)
    public static let fps23_976 = FrameRate(24000, 1001)
    public static let fps29_97 = FrameRate(30000, 1001)
    public static let fps59_94 = FrameRate(60000, 1001)

    public static let common: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60]
}

/// Half-open time range `[start, start + duration)`.
public struct TimeRange: Hashable, Sendable, Codable {
    public var start: RationalTime
    public var duration: RationalTime

    public init(start: RationalTime, duration: RationalTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: RationalTime, end: RationalTime) {
        self.start = start
        self.duration = end - start
    }

    public var end: RationalTime { start + duration }
    public func contains(_ t: RationalTime) -> Bool { t >= start && t < end }
    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }
}

/// Timecode helpers (non-drop-frame display).
public enum Timecode {
    public static func string(_ time: RationalTime, rate: FrameRate) -> String {
        let totalFrames = Swift.max(0, time.frameIndex(rate: rate))
        let fps = Int64(rate.fps.rounded())
        let frames = totalFrames % fps
        let totalSeconds = totalFrames / fps
        let s = totalSeconds % 60, m = (totalSeconds / 60) % 60, h = totalSeconds / 3600
        return String(format: "%02lld:%02lld:%02lld:%02lld", h, m, s, frames)
    }

    /// Parses `HH:MM:SS:FF`, `MM:SS:FF`, `SS:FF`, or plain seconds.
    public static func parse(_ text: String, rate: FrameRate) -> RationalTime? {
        let parts = text.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        if parts.count == 1 { return Double(parts[0]).map { RationalTime(seconds: $0).rounded(toFrame: rate) } }
        let numbers = parts.compactMap { Int64($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        let fps = Int64(rate.fps.rounded())
        var padded = Array(repeating: Int64(0), count: 4 - numbers.count) + numbers
        padded[3] = Swift.min(padded[3], fps - 1)
        let frames = ((padded[0] * 60 + padded[1]) * 60 + padded[2]) * fps + padded[3]
        return RationalTime(frames: frames, rate: rate)
    }
}
