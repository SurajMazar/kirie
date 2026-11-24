import Foundation

public struct LyricToken: Hashable, Sendable, Codable {
    public var text: String
    public var emphasised: Bool

    public init(text: String, emphasised: Bool = false) {
        self.text = text
        self.emphasised = emphasised
    }
}

/// A lyric line broken into rows of words.
public struct LyricRows: Hashable, Sendable, Codable {
    public var rows: [[LyricToken]]

    public var words: [LyricToken] { rows.flatMap { $0 } }
    public var wordCount: Int { rows.reduce(0) { $0 + $1.count } }
    public var plainText: String { rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: " ") }
}

/// Lyric markup: `*word*` (or `*several words*`) marks big, pulsing emphasis; `/` starts a new row.
/// `\*` and `\/` give literal characters.
public enum LyricMarkup {
    public static func parse(_ source: String) -> LyricRows {
        var rows: [[LyricToken]] = [[]]
        var buffer = ""
        var emphasised = false
        var escaped = false

        func flush() {
            for word in buffer.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                rows[rows.count - 1].append(LyricToken(text: String(word), emphasised: emphasised))
            }
            buffer = ""
        }

        for character in source {
            if escaped {
                buffer.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "*" {
                flush()
                emphasised.toggle()
            } else if character == "/" || character == "\n" {
                flush()
                rows.append([])
            } else {
                buffer.append(character)
            }
        }
        if escaped { buffer.append("\\") }
        flush()
        return LyricRows(rows: rows.filter { !$0.isEmpty })
    }

    /// Text with markup removed, for captions, search and export.
    public static func plainText(_ source: String) -> String { parse(source).plainText }

    /// In block style, a line without explicit emphasis makes its first word the big one.
    public static func applyingBlockDefault(_ rows: LyricRows) -> LyricRows {
        guard !rows.words.contains(where: \.emphasised), var first = rows.rows.first, !first.isEmpty else { return rows }
        first[0].emphasised = true
        var copy = rows
        copy.rows[0] = first
        return copy
    }
}

public enum WordTiming {
    public static let holdRange = 0.25...0.6

    public static func clampHold(_ hold: Double) -> Double {
        guard hold.isFinite else { return 0.4 }
        return min(max(hold, holdRange.lowerBound), holdRange.upperBound)
    }

    /// Reveal time for each word of a line.
    ///
    /// Words are spread across the whole line so lettering keeps arriving for its full length; the
    /// complete line then holds for `hold` seconds before it leaves. `overrides` (tap-to-time or
    /// manual edits) replace individual times; the result is always non-decreasing and inside the line.
    public static func distribute(wordCount: Int, start: RationalTime, end: RationalTime, hold: Double,
                                  overrides: [RationalTime?] = []) -> [RationalTime] {
        guard wordCount > 0, end > start else { return [] }
        let total = (end - start).seconds
        let wanted = clampHold(hold)
        // Very short lines: never spend more than half the line on the hold.
        let effectiveHold = min(wanted, total / 2)
        let window = max(0, total - effectiveHold)
        var times: [RationalTime] = (0..<wordCount).map { index in
            start + RationalTime(seconds: window * Double(index) / Double(wordCount))
        }
        for (index, override) in overrides.enumerated() where index < wordCount {
            if let override { times[index] = override }
        }
        var floor = start
        for index in times.indices {
            let clamped = times[index].clamped(floor, end)
            times[index] = clamped
            floor = clamped
        }
        return times
    }

    /// Number of words visible at `time`.
    public static func visibleCount(times: [RationalTime], at time: RationalTime) -> Int {
        var count = 0
        for t in times where t <= time { count += 1 }
        return count
    }
}
