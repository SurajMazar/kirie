import Foundation
import Testing
@testable import ProjectDomain

@Suite("Project file format")
struct CodecTests {
    @Test func saveLoadIsExactAndDeterministic() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        try engine.execute(.setKeyframe(clipID: a, keyframe: Keyframe(property: .scale, time: seconds(1), value: 1.2)))
        try engine.execute(.comic(.enable(number: 12, slug: "Rainy day")))
        let first = try ProjectCodec.encode(engine.project)
        let second = try ProjectCodec.encode(engine.project)
        #expect(first == second, "encoding is deterministic")
        let decoded = try ProjectCodec.decode(first)
        #expect(decoded == engine.project)
        #expect(try ProjectCodec.encode(decoded) == first)
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"duration\" : \"10/1\""), "times are readable rationals")
    }

    @Test func datesRoundTripAtEveryMillisecond() throws {
        // Regression: truncating formatters turned x.739 into x.738 for some doubles.
        for ms in stride(from: Int64(1_795_000_000_000), to: 1_795_000_003_000, by: 7) {
            let date = Date(timeIntervalSince1970: Double(ms) / 1000 + 0.0002).roundedToMilliseconds
            let text = ProjectCodec.string(from: date)
            #expect(ProjectCodec.date(from: text) == date, "\(text)")
        }
        #expect(ProjectCodec.date(from: "2026-11-24T10:46:16Z") != nil)
        #expect(ProjectCodec.date(from: "yesterday") == nil)
    }

    @Test func rejectsDamagedAndForeignFiles() {
        #expect(throws: ProjectFileError.self) { try ProjectCodec.decode(Data("{ not json".utf8)) }
        #expect(throws: ProjectFileError.self) { try ProjectCodec.decode(Data("[1,2,3]".utf8)) }
        #expect(throws: ProjectFileError.self) { try ProjectCodec.decode(Data("{\"schemaVersion\": 1}".utf8)) }
        #expect(throws: ProjectFileError.newerSchema(found: 99, supported: 1)) {
            try ProjectCodec.decode(Data("{\"schemaVersion\": 99}".utf8))
        }
    }

    @Test func rejectsStructurallyInvalidProjects() throws {
        var (engine, assets) = Fixture.stocked()
        _ = try Fixture.add(&engine, assets[0])
        var broken = engine.project
        broken.sequences[0].tracks[0].clips[0].assetID = UUID()
        let data = try ProjectCodec.encode(broken)
        #expect(throws: ProjectFileError.self) { try ProjectCodec.decode(data) }
        #expect((try? ProjectCodec.decode(data, validate: false)) != nil, "inspection tools can still read it")
    }

    @Test func migratesPreReleaseDrafts() throws {
        let project = Fixture.reel()
        var json = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(project)) as? [String: Any])
        json.removeValue(forKey: "schemaVersion")
        json.removeValue(forKey: "exportPresetID")
        var canvas = try #require(json["canvas"] as? [String: Any])
        canvas.removeValue(forKey: "colorSpace")
        json["canvas"] = canvas
        let migrated = try ProjectCodec.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(migrated.schemaVersion == 1)
        #expect(migrated.exportPresetID == "custom")
        #expect(migrated.canvas.colorSpace == .rec709)
    }

    @Test func validatorCatchesBrokenInvariants() throws {
        var (engine, assets) = Fixture.stocked()
        _ = try Fixture.add(&engine, assets[0])
        _ = try Fixture.add(&engine, assets[1])
        var gap = engine.project
        gap.sequences[0].tracks[0].clips[1].start = seconds(15)
        #expect(ProjectValidator.validate(gap).contains { $0.message.contains("gap or overlap") })
        var negative = engine.project
        negative.sequences[0].tracks[0].clips[0].duration = .zero
        #expect(ProjectValidator.validate(negative).contains { $0.message.contains("no duration") })
        var odd = engine.project
        odd.canvas.width = 1081
        #expect(ProjectValidator.validate(odd).contains { $0.message.contains("even") })
        #expect(ProjectValidator.validate(engine.project).isEmpty)
    }

    @Test func exportPresetsValidate() {
        for preset in ExportPreset.builtIn { #expect(preset.validationProblems().isEmpty, "\(preset.id)") }
        var bad = ExportPreset.builtIn[0]
        bad.width = 1081
        #expect(!bad.validationProblems().isEmpty)
        var huge = ExportPreset.builtIn[0]
        huge.width = 7680; huge.height = 4320
        #expect(huge.validationProblems().contains { $0.contains("H.264") })
        let reels = ExportPreset.matching(CanvasSettings(width: 1080, height: 1920))
        #expect(reels.id == "reels-h264")
        #expect(ExportPreset.matching(CanvasSettings(width: 1234, height: 700)).id == "custom")
        #expect(reels.estimatedFileSize(duration: seconds(10), hasAudio: true) == Int64((12_000_000 + 192_000) * 10 / 8))
    }
}

@Suite("Subtitles")
struct SubtitleTests {
    let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    Hello <i>there</i>

    2
    00:00:04,000 --> 00:00:06,000
    Second line
    wraps here

    """

    @Test func parsesAndWritesSRT() throws {
        let cues = try Subtitles.parse(srt, format: .srt)
        #expect(cues.count == 2)
        #expect(cues[0].start == RationalTime(1, 1))
        #expect(cues[0].end == RationalTime(7, 2))
        #expect(cues[0].text == "Hello there")
        #expect(cues[1].text == "Second line\nwraps here")
        let written = Subtitles.write(cues, format: .srt)
        #expect(try Subtitles.parse(written, format: .srt) == cues)
    }

    @Test func parsesVTTWithCueSettingsAndKaraokeStamps() throws {
        let vtt = """
        WEBVTT

        NOTE this is a comment

        intro
        00:01.000 --> 00:03.000 line:80% align:center
        <00:01.000>One <00:01.800>two <00:02.400>three

        00:00:04.000 --> 00:00:05.000
        Plain
        """
        let cues = try Subtitles.parse(vtt, format: .vtt)
        #expect(cues.count == 2)
        #expect(cues[0].text == "One two three")
        #expect(cues[0].words.map(\.text) == ["One", "two", "three"])
        #expect(cues[0].words[1].start == RationalTime(9, 5))
        #expect(cues[0].words[2].end == RationalTime(3, 1))
        let written = Subtitles.write(cues, format: .vtt)
        #expect(written.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n"))
    }

    @Test func parsesLRCWithOffsetsRepeatsAndGaps() throws {
        let lrc = """
        [ar:Someone]
        [offset:500]
        [00:10.00]First line
        [00:14.50][00:30.00]Repeated line
        [00:18.00]
        [00:20.00]<00:20.00>Word <00:20.80>by <00:21.20>word
        """
        let cues = try Subtitles.parse(lrc, format: .lrc, fallbackDuration: RationalTime(40, 1))
        #expect(cues.map(\.text) == ["First line", "Repeated line", "Word by word", "Repeated line"])
        #expect(cues[0].start == RationalTime(19, 2), "offset +500 ms shifts lines earlier")
        #expect(cues[1].end == RationalTime(35, 2), "a blank line ends the previous lyric")
        #expect(cues[2].words.count == 3)
        #expect(cues[3].end == RationalTime(40, 1))
        let written = Subtitles.write(cues, format: .lrc)
        #expect(written.contains("[00:09.50]First line"))
    }

    @Test func malformedInputNeverCrashes() {
        let junk = ["", "-->", "00:00:01,000 --> 00:00:00,500\nbackwards", "1\n99:99:99,999 --> x\ntext",
                    String(repeating: "[", count: 5000), "[00:xx.00]bad", "WEBVTT\n\n<<<>>>"]
        for text in junk {
            for format in SubtitleFormat.allCases {
                #expect(throws: SubtitleError.noCues) { try Subtitles.parse(text, format: format) }
            }
        }
        let big = Data(count: Subtitles.maxBytes + 1)
        #expect(throws: SubtitleError.tooLarge) { try Subtitles.parse(big, format: .srt) }
    }
}

@Suite("Lyrics")
struct LyricTests {
    @Test func markupParsesEmphasisAndRows() {
        let rows = LyricMarkup.parse("you are my *sunshine* / my only *sun shine*")
        #expect(rows.rows.count == 2)
        #expect(rows.rows[0].map(\.text) == ["you", "are", "my", "sunshine"])
        #expect(rows.rows[0].map(\.emphasised) == [false, false, false, true])
        #expect(rows.rows[1].map(\.emphasised) == [false, false, true, true])
        #expect(rows.plainText == "you are my sunshine my only sun shine")
        #expect(LyricMarkup.parse("50\\/50 \\*literal\\*").words.map(\.text) == ["50/50", "*literal*"])
        #expect(LyricMarkup.parse(" / / ").rows.isEmpty)
        let block = LyricMarkup.applyingBlockDefault(LyricMarkup.parse("good girl"))
        #expect(block.words.map(\.emphasised) == [true, false])
    }

    @Test func wordsSpreadAcrossTheLineThenHold() {
        let times = WordTiming.distribute(wordCount: 4, start: seconds(10), end: seconds(12.4), hold: 0.4)
        #expect(times.count == 4)
        #expect(times[0] == seconds(10))
        #expect(abs(times[3].seconds - 11.5) < 1e-6, "last word arrives one step before the hold")
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        // The hold is clamped to 0.25–0.6 s.
        #expect(WordTiming.clampHold(5) == 0.6)
        #expect(WordTiming.clampHold(0) == 0.25)
        let long = WordTiming.distribute(wordCount: 2, start: .zero, end: seconds(4), hold: 9)
        #expect(abs(long[1].seconds - 1.7) < 1e-6)
    }

    @Test func tapOverridesStayOrderedAndInsideTheLine() {
        let times = WordTiming.distribute(wordCount: 4, start: seconds(1), end: seconds(3), hold: 0.4,
                                          overrides: [nil, seconds(2.5), seconds(1.2), seconds(99)])
        #expect(times[1] == seconds(2.5))
        #expect(times[2] == seconds(2.5), "an earlier tap cannot jump behind the previous word")
        #expect(times[3] == seconds(3))
        #expect(WordTiming.visibleCount(times: times, at: seconds(2.6)) == 3)
        #expect(WordTiming.distribute(wordCount: 0, start: .zero, end: seconds(1), hold: 0.4).isEmpty)
    }
}

@Suite("Snapping")
struct SnappingTests {
    @Test func snapsToNearestTargetWithinTolerance() throws {
        var (engine, assets) = Fixture.stocked()
        _ = try Fixture.add(&engine, assets[0])
        try engine.execute(.replaceBeatMarkers(sequenceID: nil, markers: [Marker(time: seconds(4.5), kind: .beat)]))
        let targets = Snapping.targets(in: engine.project.activeSequence, playhead: seconds(7))
        let tolerance = seconds(0.2)
        #expect(Snapping.snap(seconds(9.9), to: targets, tolerance: tolerance).time == seconds(10))
        #expect(Snapping.snap(seconds(4.4), to: targets, tolerance: tolerance).target?.kind == .beat)
        #expect(Snapping.snap(seconds(7.1), to: targets, tolerance: tolerance).target?.kind == .playhead)
        #expect(Snapping.snap(seconds(6), to: targets, tolerance: tolerance).target == nil)
        #expect(Snapping.snap(seconds(6), to: targets, tolerance: tolerance).time == seconds(6))
    }
}
