import Foundation

public enum SubtitleFormat: String, Sendable, CaseIterable {
    case srt, vtt, lrc

    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}

public enum SubtitleError: Error, Equatable, LocalizedError {
    case tooLarge
    case noCues
    case notText

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The subtitle file is too large (limit 8 MB)."
        case .noCues: "No timed lines were found in the file."
        case .notText: "The file is not readable text."
        }
    }
}

/// Parsers and writers for SRT, WebVTT and LRC. Input is untrusted: parsing is tolerant, bounded and
/// never traps on malformed files.
public enum Subtitles {
    public static let maxBytes = 8 * 1024 * 1024
    public static let maxCues = 20_000

    public static func parse(_ data: Data, format: SubtitleFormat, fallbackDuration: RationalTime? = nil) throws -> [CaptionSegment] {
        guard data.count <= maxBytes else { throw SubtitleError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1) else { throw SubtitleError.notText }
        return try parse(text, format: format, fallbackDuration: fallbackDuration)
    }

    public static func parse(_ text: String, format: SubtitleFormat, fallbackDuration: RationalTime? = nil) throws -> [CaptionSegment] {
        guard text.utf8.count <= maxBytes else { throw SubtitleError.tooLarge }
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let cues: [CaptionSegment] = switch format {
        case .srt: parseBlocks(normalised, isVTT: false)
        case .vtt: parseBlocks(normalised, isVTT: true)
        case .lrc: parseLRC(normalised, fallbackDuration: fallbackDuration)
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        return Array(cues.prefix(maxCues))
    }

    public static func write(_ segments: [CaptionSegment], format: SubtitleFormat) -> String {
        let sorted = segments.sorted { $0.start < $1.start }
        switch format {
        case .srt:
            return sorted.enumerated().map { index, cue in
                "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(cue.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            let body = sorted.map { cue in
                "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(cue.text)\n"
            }.joined(separator: "\n")
            return "WEBVTT\n\n" + body
        case .lrc:
            return sorted.map { cue in
                let line = cue.text.replacingOccurrences(of: "\n", with: " ")
                if cue.words.isEmpty { return "[\(lrcStamp(cue.start))]\(line)" }
                let words = cue.words.map { "<\(lrcStamp($0.start))>\($0.text)" }.joined(separator: " ")
                return "[\(lrcStamp(cue.start))]\(words)"
            }.joined(separator: "\n") + "\n"
        }
    }

    // MARK: Timestamps

    static func stamp(_ time: RationalTime, separator: String) -> String {
        let ms = max(0, Int64((time.seconds * 1000).rounded()))
        return String(format: "%02lld:%02lld:%02lld%@%03lld", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
    }

    static func lrcStamp(_ time: RationalTime) -> String {
        let cs = max(0, Int64((time.seconds * 100).rounded()))
        return String(format: "%02lld:%02lld.%02lld", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    /// Parses `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm` or `MM:SS.xx`.
    static func parseStamp(_ raw: String) -> RationalTime? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let seconds = Double(parts[parts.count - 1]), seconds.isFinite, seconds >= 0, seconds < 60.0001 else { return nil }
        guard let minutes = Int64(parts[parts.count - 2]), minutes >= 0 else { return nil }
        var hours: Int64 = 0
        if parts.count == 3 {
            guard let h = Int64(parts[0]), h >= 0, h < 1000 else { return nil }
            hours = h
        }
        guard minutes < 6000 else { return nil }
        let total = Double(hours * 3600 + minutes * 60) + seconds
        return RationalTime(Int64((total * 1000).rounded()), 1000)
    }

    // MARK: SRT / VTT

    private static func parseBlocks(_ text: String, isVTT: Bool) -> [CaptionSegment] {
        var cues: [CaptionSegment] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if isVTT, let first = lines.first, first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }
            let sides = lines[timeIndex].components(separatedBy: "-->")
            guard sides.count == 2 else { continue }
            let endToken = sides[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard let start = parseStamp(sides[0]), let end = parseStamp(endToken), end > start else { continue }
            let raw = lines[(timeIndex + 1)...].joined(separator: "\n")
            let (clean, words) = extractWords(raw, cueStart: start, cueEnd: end)
            guard !clean.isEmpty else { continue }
            cues.append(CaptionSegment(start: start, end: end, text: clean, words: words))
            if cues.count >= maxCues { break }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Strips markup tags and collects karaoke-style inline timestamps (`<00:00:01.000>`).
    private static func extractWords(_ raw: String, cueStart: RationalTime, cueEnd: RationalTime) -> (String, [TimedWord]) {
        var plain = ""
        var marks: [(offset: Int, time: RationalTime)] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "<", let close = raw[index...].firstIndex(of: ">") {
                let tag = String(raw[raw.index(after: index)..<close])
                if let time = parseStamp(tag) { marks.append((plain.count, time)) }
                index = raw.index(after: close)
            } else if character == "{", let close = raw[index...].firstIndex(of: "}") {
                index = raw.index(after: close)
            } else {
                plain.append(character)
                index = raw.index(after: index)
            }
        }
        let clean = plain.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard !marks.isEmpty else { return (clean, []) }
        // Words are the text between consecutive timestamps.
        var words: [TimedWord] = []
        let characters = Array(plain)
        var boundaries = marks
        if boundaries.first?.offset != 0 { boundaries.insert((0, cueStart), at: 0) }
        for (i, mark) in boundaries.enumerated() {
            let endOffset = i + 1 < boundaries.count ? boundaries[i + 1].offset : characters.count
            guard mark.offset < endOffset, endOffset <= characters.count else { continue }
            let chunk = String(characters[mark.offset..<endOffset]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            let end = i + 1 < boundaries.count ? boundaries[i + 1].time : cueEnd
            words.append(TimedWord(text: chunk, start: mark.time, end: RationalTime.max(end, mark.time)))
        }
        return (clean, words)
    }

    // MARK: LRC

    private static func parseLRC(_ text: String, fallbackDuration: RationalTime?) -> [CaptionSegment] {
        struct Entry { var start: RationalTime; var text: String; var words: [(RationalTime, String)] }
        var entries: [Entry] = []
        var offsetMs: Int64 = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [RationalTime] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = String(line[line.index(after: line.startIndex)..<close])
                if let time = parseStamp(tag) {
                    stamps.append(time)
                } else if tag.lowercased().hasPrefix("offset:"), let value = Int64(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offsetMs = max(-600_000, min(600_000, value))
                }
                line = line[line.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            // Enhanced LRC: <mm:ss.xx>word
            var plain = ""
            var words: [(RationalTime, String)] = []
            var pending: RationalTime?
            var buffer = ""
            var index = line.startIndex
            func flush() {
                let word = buffer.trimmingCharacters(in: .whitespaces)
                if let time = pending, !word.isEmpty { words.append((time, word)) }
                buffer = ""
            }
            while index < line.endIndex {
                if line[index] == "<", let close = line[index...].firstIndex(of: ">"),
                   let time = parseStamp(String(line[line.index(after: index)..<close])) {
                    flush()
                    pending = time
                    index = line.index(after: close)
                } else {
                    plain.append(line[index])
                    buffer.append(line[index])
                    index = line.index(after: index)
                }
            }
            flush()
            let clean = plain.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            for stamp in stamps {
                entries.append(Entry(start: stamp, text: clean, words: stamps.count == 1 ? words : []))
            }
            if entries.count >= maxCues { break }
        }
        entries.sort { $0.start < $1.start }
        let shift = RationalTime(-offsetMs, 1000)
        var cues: [CaptionSegment] = []
        for (index, entry) in entries.enumerated() {
            let start = RationalTime.max(.zero, entry.start + shift)
            var end: RationalTime
            if index + 1 < entries.count {
                end = RationalTime.max(.zero, entries[index + 1].start + shift)
            } else {
                end = fallbackDuration.map { RationalTime.max($0, start + RationalTime(1, 1)) } ?? start + RationalTime(4, 1)
            }
            // Blank lines mark instrumental gaps: they end the previous line but produce no cue.
            guard !entry.text.isEmpty, end > start else { continue }
            end = RationalTime.max(end, start + RationalTime(1, 100))
            let words: [TimedWord] = entry.words.enumerated().map { wi, word in
                let wordStart = RationalTime.max(.zero, word.0 + shift)
                let wordEnd = wi + 1 < entry.words.count ? RationalTime.max(.zero, entry.words[wi + 1].0 + shift) : end
                return TimedWord(text: word.1, start: wordStart, end: RationalTime.max(wordEnd, wordStart))
            }
            cues.append(CaptionSegment(start: start, end: end, text: entry.text, words: words))
        }
        return cues
    }
}
