import AVFoundation
import Foundation
import Testing
@testable import MediaServices
import ProjectDomain

func mediaScratch(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kirie-media-\(safe)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Media probing and previews")
struct ProbeTests {
    @Test func probesGeneratedVideoWithSound() async throws {
        let root = try mediaScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clip.mov")
        try await SampleMedia.writeTestVideo(to: url, width: 640, height: 360, fps: 30, seconds: 2,
                                             color: RGBAColor(r: 0.2, g: 0.4, b: 0.8), label: "A", toneFrequency: 440)
        let (kind, metadata) = try await MediaProbe.probe(url)
        #expect(kind == .video)
        #expect(metadata.width == 640 && metadata.height == 360)
        #expect(abs(metadata.duration.seconds - 2) < 0.05)
        #expect(abs(metadata.frameRate - 30) < 0.5)
        #expect(metadata.videoCodec == "avc1")
        #expect(metadata.hasAudio && metadata.audioChannels == 1 && metadata.sampleRate == 44_100)
        #expect(metadata.rotationDegrees == 0)
        #expect(!metadata.isHDR)

        let thumbnail = try await Thumbnailer.image(for: url, kind: .video, maxPixel: 160)
        #expect(max(thumbnail.width, thumbnail.height) <= 160)
        let strip = try await Thumbnailer.filmstrip(for: url, count: 4, maxPixel: 80)
        #expect(strip.count == 4)
        #expect(strip.map(\.seconds) == [0.25, 0.75, 1.25, 1.75])
    }

    @Test func probesAudioAndImages() async throws {
        let root = try mediaScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("tone.wav")
        try SampleMedia.writeTone(to: wav, frequency: 220, seconds: 1.5)
        let (audioKind, audio) = try await MediaProbe.probe(wav)
        #expect(audioKind == .audio)
        #expect(abs(audio.duration.seconds - 1.5) < 0.01)
        #expect(!audio.hasVideo && audio.hasAudio)

        let png = root.appendingPathComponent("still.png")
        try SampleMedia.writeStill(to: png, width: 400, height: 600, color: .paper, label: "still")
        let (imageKind, image) = try await MediaProbe.probe(png)
        #expect(imageKind == .image)
        #expect(image.width == 400 && image.height == 600)
        #expect(image.duration == .zero)
        let thumbnail = try await Thumbnailer.image(for: png, kind: .image, maxPixel: 100)
        #expect(thumbnail.height == 100)
    }

    @Test func rejectsBadFilesWithActionableErrors() async throws {
        let root = try mediaScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: MediaError.missing("nope.mov")) { try await MediaProbe.probe(root.appendingPathComponent("nope.mov")) }

        let empty = root.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        await #expect(throws: MediaError.empty("empty.png")) { try await MediaProbe.probe(empty) }

        let text = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: MediaError.self) { try await MediaProbe.probe(text) }

        // Garbage with a media extension must fail cleanly, not crash.
        for name in ["fake.mov", "fake.png", "fake.mp3"] {
            let fake = root.appendingPathComponent(name)
            try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: fake)
            await #expect(throws: MediaError.self) { try await MediaProbe.probe(fake) }
        }
    }

    @Test func rotationMetadataIsNormalised() {
        #expect(MediaProbe.rotationDegrees(.identity) == 0)
        #expect(MediaProbe.rotationDegrees(CGAffineTransform(rotationAngle: .pi / 2)) == 90)
        #expect(MediaProbe.rotationDegrees(CGAffineTransform(rotationAngle: .pi)) == 180)
        #expect(MediaProbe.rotationDegrees(CGAffineTransform(rotationAngle: -.pi / 2)) == 270)
    }

    @Test func timeBridgingIsExact() {
        #expect(RationalTime(1001, 30000).cmTime == CMTime(value: 1001, timescale: 30000))
        #expect(RationalTime(CMTime(value: 300, timescale: 600)) == RationalTime(1, 2))
        #expect(RationalTime(CMTime.invalid) == .zero)
        #expect(FrameRate.fps29_97.cmFrameDuration == CMTime(value: 1001, timescale: 30000))
    }
}

@Suite("Audio analysis")
struct AudioTests {
    @Test func waveformFollowsTheSound() async throws {
        let root = try mediaScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clicks.wav")
        try SampleMedia.writeClickTrack(to: url, bpm: 60, seconds: 4, firstBeat: 0.5)
        let waveform = try await WaveformGenerator.generate(url, peaksPerSecond: 100)
        #expect(abs(waveform.duration - 4) < 0.05)
        #expect(waveform.peak(from: 0.5, to: 0.56) > 0.3, "a click is loud")
        #expect(waveform.peak(from: 1.0, to: 1.4) < 0.02, "between clicks is silent")
        #expect(waveform.peaks.allSatisfy { $0 >= 0 && $0 <= 1 })

        let restored = try #require(Waveform(data: waveform.data))
        #expect(restored == waveform)
        #expect(Waveform(data: Data("nonsense".utf8)) == nil)
        #expect(Waveform(data: waveform.data.dropLast(3)) == nil, "truncated cache files are rejected")
    }

    @Test(arguments: [90.0, 120.0, 128.0, 150.0])
    func detectsTempoAndBeats(bpm: Double) async throws {
        let root = try mediaScratch("beats\(Int(bpm))")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clicks.wav")
        let firstBeat = 0.25
        try SampleMedia.writeClickTrack(to: url, bpm: bpm, seconds: 24, firstBeat: firstBeat)
        let analysis = try await BeatDetector.analyse(url)
        #expect(abs(analysis.bpm - bpm) < 1.5, "detected \(analysis.bpm) for \(bpm)")
        #expect(analysis.confidence > 0.3)

        // Every detected beat (ignoring the edges) sits on the true grid.
        let interval = 60 / bpm
        let inner = analysis.beats.filter { $0 > 1 && $0 < 22 }
        #expect(inner.count >= Int(20 / interval) - 2)
        for beat in inner {
            let phase = (beat - firstBeat) / interval
            let error = abs(phase - phase.rounded()) * interval
            #expect(error < 0.04, "beat at \(beat) is \(error)s off the grid")
        }
        // The accented beat (every fourth, starting with the first) is found as the bar start.
        #expect(analysis.downbeatConfidence > 0.2)
        let bar = try #require(analysis.downbeats.first.map { analysis.beats[$0] })
        let barPhase = (bar - firstBeat) / (interval * 4)
        #expect(abs(barPhase - barPhase.rounded()) * interval * 4 < 0.05, "bar start \(bar) is not on an accented beat")
    }

    @Test func silenceAndShortClipsGiveNoBeats() async throws {
        #expect(BeatDetector.analyse(samples: [Float](repeating: 0, count: 22_050 * 5), sampleRate: 22_050) == .none)
        #expect(BeatDetector.analyse(samples: [0.1, 0.2], sampleRate: 22_050) == .none)
    }

    @Test func beatsBecomeTimelineMarkers() {
        let analysis = BeatAnalysis(bpm: 120, confidence: 0.9, beats: [0.5, 1.0, 1.5, 2.0, 2.5], downbeats: [0, 4], downbeatConfidence: 0.8)
        // The song clip starts at 10 s on the timeline, trimmed 1 s into the source, and lasts 1.2 s.
        let markers = analysis.markers(offset: RationalTime(10, 1), sourceStart: RationalTime(1, 1), limit: RationalTime(seconds: 1.2))
        #expect(markers.map(\.time) == [RationalTime(10, 1), RationalTime(21, 2), RationalTime(11, 1)])
        #expect(markers.map(\.kind) == [.beat, .beat, .beat])
        #expect(analysis.markers().map(\.kind) == [.downbeat, .beat, .beat, .beat, .downbeat])
    }
}
