import AVFoundation
import Foundation
import MediaServices
import ProjectDomain
import Testing
@testable import RenderEngine

/// A project with two videos, a still, a title, a song and a transition: the "new Reel" scenario.
struct ReelFixture {
    var engine: CommandEngine
    var root: URL
    var videoA: MediaAsset
    var videoB: MediaAsset
    var still: MediaAsset
    var song: MediaAsset
    var clipIDs: [UUID]

    static func make(_ name: String = #function, songRights: RightsStatus = .owned) async throws -> ReelFixture {
        let root = try renderScratch(name)
        let aURL = root.appendingPathComponent("a.mov"), bURL = root.appendingPathComponent("b.mov")
        let stillURL = root.appendingPathComponent("still.png"), songURL = root.appendingPathComponent("song.wav")
        try await SampleMedia.writeTestVideo(to: aURL, width: 360, height: 640, seconds: 2, color: red, label: "A", toneFrequency: 330)
        try await SampleMedia.writeTestVideo(to: bURL, width: 640, height: 360, seconds: 2, color: blue, label: "B")
        try SampleMedia.writeStill(to: stillURL, width: 360, height: 640, color: green, label: "")
        try SampleMedia.writeTone(to: songURL, frequency: 220, seconds: 8, amplitude: 0.25)
        var engine = CommandEngine(project: Project(name: "Reel", canvas: CanvasSettings(width: 1080, height: 1920, frameRate: .fps30)))
        let a = try await importAsset(aURL), b = try await importAsset(bURL), still = try await importAsset(stillURL)
        let song = try await importAsset(songURL, rights: songRights)
        try engine.execute(.importAssets(assets: [a, b, still, song]))
        var ids: [UUID] = []
        for asset in [a, b, still] {
            let id = UUID()
            try engine.execute(.addClip(sequenceID: nil, clipID: id, assetID: asset.id, trackID: nil, start: nil, sourceStart: nil,
                                        duration: asset.kind == .image ? t(2) : nil, index: nil))
            ids.append(id)
        }
        return ReelFixture(engine: engine, root: root, videoA: a, videoB: b, still: still, song: song, clipIDs: ids)
    }

    func export(_ preset: ExportPreset = testPreset(), name: String = "out", range: TimeRange? = nil, options: RenderOptions = RenderOptions(),
                note: SongNote? = nil, cancellation: ExportCancellation = ExportCancellation(),
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExportReport {
        let destination = root.appendingPathComponent("\(name).\(preset.container.fileExtension)")
        return try await Exporter.export(project: engine.project, resolver: pathResolver,
                                         request: ExportRequest(preset: preset, destination: destination, range: range, options: options, songNote: note),
                                         cancellation: cancellation, progress: progress)
    }
}

@Suite("Export pipeline", .serialized)
struct ExportTests {
    @Test func exportsAVerifiedReel() async throws {
        var fixture = try await ReelFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Title, song, a dissolve between the two videos and a page fold into the still.
        var title = Clip(kind: .text, name: "Title", start: t(0.2), duration: t(1.5),
                         text: TextContent(string: "KIRIE", style: TextStyle(fontSize: 160, shadow: nil), animation: .pop))
        title.transform.position = UnitPoint2D(x: 0.5, y: 0.12)
        try fixture.engine.execute(.insertClip(sequenceID: nil, trackID: nil, clip: title, index: nil))
        try fixture.engine.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: fixture.song.id, trackID: nil, start: .zero, sourceStart: nil, duration: t(5), index: nil))
        try fixture.engine.execute(.setTransition(clipID: fixture.clipIDs[1], transition: Transition(type: .dissolve, duration: t(0.5))))
        try fixture.engine.execute(.setTransition(clipID: fixture.clipIDs[2], transition: Transition(type: .pageFold, duration: t(0.5))))
        let expectedDuration = fixture.engine.project.activeSequence.duration.seconds
        #expect(abs(expectedDuration - 5) < 1e-9)

        let progressLog = ProgressLog()
        let report = try await fixture.export(progress: { progressLog.record($0) })
        #expect(report.verification.passed, "\(report.verification.failures)")
        #expect(report.hasAudio)
        #expect(report.framesWritten == 150)
        #expect(report.fileSize > 20_000)
        #expect(progressLog.values.last == 1)
        #expect(progressLog.values == progressLog.values.sorted(), "progress never goes backwards")

        // Independent check of the file on disk.
        let url = URL(fileURLWithPath: report.outputPath)
        let (kind, metadata) = try await MediaProbe.probe(url)
        #expect(kind == .video && metadata.width == 360 && metadata.height == 640)
        #expect(metadata.videoCodec == "avc1" && metadata.hasAudio)
        #expect(abs(metadata.duration.seconds - expectedDuration) < 0.12)

        // The right picture is on screen at the right time.
        let first = try await frame(of: url, at: 0.9)
        #expect(first.pixel(0.5, 0.75).isClose(to: (0.9, 0.1, 0.1), tolerance: 0.14), "video A (red) at 0.9 s: \(first.pixel(0.5, 0.75))")
        #expect(first.coverage(in: CGRect(x: 0.1, y: 0.06, width: 0.8, height: 0.12), differingFrom: (0.9, 0.1, 0.1), threshold: 0.3) > 0.05, "title is drawn")
        let second = try await frame(of: url, at: 2.6)
        // Video B is landscape on a portrait canvas: contained, so blue in the middle and black above.
        #expect(second.pixel(0.5, 0.42).isClose(to: (0.1, 0.2, 0.9), tolerance: 0.14), "video B (blue) at 2.6 s: \(second.pixel(0.5, 0.42))")
        #expect(second.pixel(0.5, 0.1).isClose(to: (0, 0, 0), tolerance: 0.08))
        let third = try await frame(of: url, at: 4.6)
        #expect(third.pixel(0.2, 0.2).isClose(to: (0.1, 0.8, 0.2), tolerance: 0.14), "still (green) at 4.6 s: \(third.pixel(0.2, 0.2))")
        // Halfway through the dissolve the frame is a mix of red and blue.
        let mixed = try await frame(of: url, at: 1.75).pixel(0.5, 0.42)
        #expect(mixed.r > 0.25 && mixed.b > 0.25, "dissolve midpoint: \(mixed)")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("out.song-note.txt").path))
    }

    @Test func burnedInFrameNumbersProveFrameAccuracy() async throws {
        // Trim two seconds of video to frames 30…44 and check the first exported frame is source frame 30.
        let root = try renderScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("count.mov")
        try await SampleMedia.writeTestVideo(to: url, width: 360, height: 640, seconds: 2, color: RGBAColor(r: 0.3, g: 0.3, b: 0.3), label: "N")
        var engine = CommandEngine(project: Project(name: "Accuracy", canvas: CanvasSettings(width: 360, height: 640, frameRate: .fps30)))
        let asset = try await importAsset(url)
        try engine.execute(.importAssets(assets: [asset]))
        try engine.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: asset.id, trackID: nil, start: nil, sourceStart: t(1), duration: t(0.5), index: nil))
        let built = try await CompositionBuilder.build(project: engine.project, resolver: pathResolver)
        // The sweep bar's position encodes the frame number within each second: at frame 30 it is at the far left, at 44 nearly halfway.
        func barCentre(_ seconds: Double) async throws -> Double {
            let bitmap = Bitmap(try await Exporter.still(built: built, at: t(seconds)))!
            var sum = 0.0, count = 0.0
            for step in 0..<360 {
                let x = (Double(step) + 0.5) / 360
                let pixel = bitmap.pixel(x, 0.96)
                if pixel.r > 0.75 && pixel.g > 0.75 { sum += x; count += 1 }
            }
            return count > 0 ? sum / count : -1
        }
        let start = try await barCentre(0), later = try await barCentre(14.0 / 30)
        #expect(start >= 0 && start < 0.06, "first frame shows source frame 30 (bar at the left): \(start)")
        #expect(abs(later - (14.0 / 30 * 340 + 10) / 360) < 0.03, "frame 14 of the clip shows source frame 44: \(later)")
    }

    @Test func rangeExportAndStill() async throws {
        let fixture = try await ReelFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let report = try await fixture.export(name: "range", range: TimeRange(start: t(2), duration: t(1.5)))
        #expect(report.verification.passed)
        #expect(abs(report.durationSeconds - 1.5) < 1e-9)
        #expect(report.framesWritten == 45)
        // The range starts on video B.
        let first = try await frame(of: URL(fileURLWithPath: report.outputPath), at: 0.2)
        #expect(first.pixel(0.5, 0.42).isClose(to: (0.1, 0.2, 0.9), tolerance: 0.14))
        await #expect(throws: RenderError.self) { try await fixture.export(name: "bad", range: TimeRange(start: t(60), duration: t(1))) }

        let built = try await CompositionBuilder.build(project: fixture.engine.project, resolver: pathResolver, outputSize: CGSize(width: 360, height: 640))
        let still = Bitmap(try await Exporter.still(built: built, at: t(5)))!
        #expect(still.pixel(0.2, 0.2).isClose(to: (0.1, 0.8, 0.2), tolerance: 0.1))
    }

    @Test func audioGainFadesAndMuting() async throws {
        let root = try renderScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let songURL = root.appendingPathComponent("tone.wav")
        try SampleMedia.writeTone(to: songURL, frequency: 440, seconds: 6, amplitude: 0.2)
        let song = try await importAsset(songURL, rights: .owned)

        func level(_ configure: (inout CommandEngine, UUID, UUID) throws -> Void, from: Double, to: Double) async throws -> Double {
            var engine = CommandEngine(project: Project(name: "Audio", canvas: CanvasSettings(width: 360, height: 640)))
            try engine.execute(.importAssets(assets: [song]))
            try add(&engine, solid(.black, duration: 4))
            let id = UUID()
            try engine.execute(.addClip(sequenceID: nil, clipID: id, assetID: song.id, trackID: nil, start: .zero, sourceStart: nil, duration: t(4), index: nil))
            let track = try #require(engine.project.activeSequence.tracks.first { $0.kind == .audio })
            try configure(&engine, id, track.id)
            let destination = root.appendingPathComponent("\(UUID().uuidString).mp4")
            let report = try await Exporter.export(project: engine.project, resolver: pathResolver, request: ExportRequest(preset: testPreset(), destination: destination))
            if !report.hasAudio { return 0 }
            return try await audioLevel(of: destination, from: from, to: to)
        }

        let unity = try await level({ _, _, _ in }, from: 1, to: 3)
        #expect(unity > 0.1 && unity < 0.2, "0.2 amplitude sine ≈ 0.14 RMS, got \(unity)")
        let half = try await level({ engine, id, _ in try engine.execute(.setClipAudio(clipID: id, audio: ClipAudio(gain: 0.5))) }, from: 1, to: 3)
        #expect(abs(half / unity - 0.5) < 0.08, "50% gain halves the level: \(half / unity)")
        let boosted = try await level({ engine, id, _ in try engine.execute(.setClipAudio(clipID: id, audio: ClipAudio(gain: 2))) }, from: 1, to: 3)
        #expect(abs(boosted / unity - 2) < 0.25, "200% gain doubles the level: \(boosted / unity)")
        let trackHalf = try await level({ engine, _, track in try engine.execute(.setTrackState(trackID: track, muted: nil, hidden: nil, locked: nil, gain: 0.5, name: nil)) }, from: 1, to: 3)
        #expect(abs(trackHalf / unity - 0.5) < 0.08)

        // Fades: quiet at the very start and end, full in the middle.
        let fade: (inout CommandEngine, UUID, UUID) throws -> Void = { engine, id, _ in
            try engine.execute(.setClipAudio(clipID: id, audio: ClipAudio(gain: 1, fadeIn: t(1), fadeOut: t(1))))
        }
        let head = try await level(fade, from: 0.05, to: 0.2), middle = try await level(fade, from: 1.5, to: 2.5), tail = try await level(fade, from: 3.8, to: 3.95)
        #expect(head < middle * 0.3 && tail < middle * 0.3, "fade in \(head), middle \(middle), fade out \(tail)")
        #expect(abs(middle / unity - 1) < 0.08)

        // Volume keyframes ride the level.
        let ride: (inout CommandEngine, UUID, UUID) throws -> Void = { engine, id, _ in
            try engine.execute(.setKeyframe(clipID: id, keyframe: Keyframe(property: .volume, time: t(1), value: 1, easing: .linear)))
            try engine.execute(.setKeyframe(clipID: id, keyframe: Keyframe(property: .volume, time: t(2), value: 0.2, easing: .linear)))
        }
        let before = try await level(ride, from: 0.2, to: 0.8), after = try await level(ride, from: 2.5, to: 3.5)
        #expect(abs(after / before - 0.2) < 0.06, "keyframed volume: \(after / before)")

        // Muted clips and muted tracks produce no audio track at all.
        #expect(try await level({ engine, id, _ in try engine.execute(.setClipAudio(clipID: id, audio: ClipAudio(muted: true))) }, from: 1, to: 3) == 0)
        #expect(try await level({ engine, _, track in try engine.execute(.setTrackState(trackID: track, muted: true, hidden: nil, locked: nil, gain: nil, name: nil)) }, from: 1, to: 3) == 0)
    }

    @Test func commercialSongsAreNeverBakedIn() async throws {
        var fixture = try await ReelFixture.make(songRights: .commercialUnlicensed)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Mute video A's own tone so the song is the only sound.
        try fixture.engine.execute(.setClipAudio(clipID: fixture.clipIDs[0], audio: ClipAudio(muted: true)))
        try fixture.engine.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: fixture.song.id, trackID: nil, start: .zero, sourceStart: nil, duration: t(6), index: nil))
        let note = SongNote(title: "Golden Hour", artist: "Some Artist", section: "start at the chorus, 0:45")
        let report = try await fixture.export(name: "silent", note: note)
        #expect(report.verification.passed)
        #expect(!report.hasAudio, "the commercial track was left out")
        #expect(report.withheldAudio == ["song.wav"])
        let (_, metadata) = try await MediaProbe.probe(URL(fileURLWithPath: report.outputPath))
        #expect(!metadata.hasAudio)
        let notePath = try #require(report.songNotePath)
        let text = try String(contentsOfFile: notePath, encoding: .utf8)
        #expect(text.contains("Golden Hour") && text.contains("start at the chorus, 0:45") && text.contains("exported without its music"))

        // Once the user declares rights, the same timeline exports with sound.
        try fixture.engine.execute(.updateAssetInfo(assetID: fixture.song.id, name: nil, rights: RightsInfo(status: .licensed), favourite: nil, rating: nil, keywords: nil, bpm: nil))
        let licensed = try await fixture.export(name: "licensed")
        #expect(licensed.hasAudio && licensed.withheldAudio.isEmpty && licensed.songNotePath == nil)
    }

    @Test func failuresLeaveNoFinishedLookingFile() async throws {
        var fixture = try await ReelFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        func leftovers() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []).filter { $0.contains("out") || $0.contains(".partial") }
        }
        // Cancelled mid-flight.
        let cancellation = ExportCancellation()
        await #expect(throws: RenderError.cancelled) {
            try await fixture.export(cancellation: cancellation, progress: { if $0 > 0.2 { cancellation.cancel() } })
        }
        #expect(leftovers().isEmpty, "cancel removed the partial file: \(leftovers())")

        // Invalid settings are rejected before any rendering.
        var odd = testPreset()
        odd.width = 361
        await #expect(throws: RenderError.self) { try await fixture.export(odd) }

        // Missing media is reported by name.
        try FileManager.default.removeItem(atPath: fixture.videoB.reference.absolutePath)
        await #expect(throws: RenderError.missingMedia(["b.mov"])) { try await fixture.export() }
        #expect(leftovers().isEmpty)

        // An empty timeline cannot be exported.
        let empty = Project(name: "Empty", canvas: CanvasSettings(width: 360, height: 640))
        await #expect(throws: RenderError.emptyTimeline) {
            try await Exporter.export(project: empty, resolver: pathResolver, request: ExportRequest(preset: testPreset(), destination: fixture.root.appendingPathComponent("empty.mp4")))
        }
    }

    @Test(arguments: [VideoCodec.hevc, VideoCodec.proRes422])
    func otherCodecsWhenTheMacSupportsThem(codec: VideoCodec) async throws {
        guard Exporter.encoderAvailable(codec) else { return }
        let fixture = try await ReelFixture.make("codec\(codec.rawValue)")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let report = try await fixture.export(testPreset(codec: codec), name: codec.rawValue, range: TimeRange(start: .zero, duration: t(1)))
        #expect(report.verification.passed, "\(report.verification.failures)")
        let (_, metadata) = try await MediaProbe.probe(URL(fileURLWithPath: report.outputPath))
        #expect(metadata.videoCodec == Exporter.fourCC(for: codec))
    }

    @Test func speedChangesPlayTheWholeSourceFaster() async throws {
        let fixture = try await ReelFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var engine = fixture.engine
        try engine.execute(.setSpeed(clipID: fixture.clipIDs[0], speed: 2))
        #expect(engine.project.activeSequence.duration == t(5))
        let destination = fixture.root.appendingPathComponent("fast.mp4")
        let report = try await Exporter.export(project: engine.project, resolver: pathResolver, request: ExportRequest(preset: testPreset(), destination: destination))
        #expect(report.verification.passed)
        #expect(abs(report.durationSeconds - 5) < 1e-9)
        // Video A now ends at 1 s, so 1.5 s is already video B.
        #expect(try await frame(of: destination, at: 1.5).pixel(0.5, 0.42).isClose(to: (0.1, 0.2, 0.9), tolerance: 0.14))
        #expect(try await frame(of: destination, at: 0.5).pixel(0.5, 0.75).isClose(to: (0.9, 0.1, 0.1), tolerance: 0.14))
    }

    @Test func audioOnlyExport() async throws {
        let fixture = try await ReelFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let built = try await CompositionBuilder.build(project: fixture.engine.project, resolver: pathResolver)
        let destination = fixture.root.appendingPathComponent("mix.wav")
        try await Exporter.exportAudio(built: built, to: destination)
        let (kind, metadata) = try await MediaProbe.probe(destination)
        #expect(kind == .audio && metadata.sampleRate == 48_000 && metadata.audioChannels == 2)
        // Video A carries a tone for its two seconds; the rest of the timeline is silent.
        #expect(try await audioLevel(of: destination, from: 0.5, to: 1.5) > 0.1)
        #expect(try await audioLevel(of: destination, from: 3, to: 4) < 0.005)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func record(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}
