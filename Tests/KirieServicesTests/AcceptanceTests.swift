import AVFoundation
import ComicStudio
import Foundation
import MediaServices
import Persistence
import ProjectDomain
import RenderEngine
import Testing
@testable import KirieServices

func scenarioFolder(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kirie-accept-\(safe)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func s(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

let smallPreset = ExportPreset(id: "test-small", name: "Small", platform: "Test", width: 360, height: 640, frameRate: .fps30, videoBitrate: 2_000_000)

func pixelAt(_ url: URL, seconds: Double, x: Double, y: Double) async throws -> (r: Double, g: Double, b: Double) {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw so the wanted pixel (top-left origin) lands on the single output pixel.
    context.draw(image, in: CGRect(x: -x * Double(image.width), y: -(1 - y) * Double(image.height) + 1, width: Double(image.width), height: Double(image.height)))
    return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
}

/// The end-to-end acceptance scenarios from the product brief, run against real files.
@Suite("Acceptance scenarios", .serialized)
struct AcceptanceTests {
    // Scenario 1
    @Test func newReel() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let colors = [RGBAColor(r: 0.85, g: 0.2, b: 0.2), RGBAColor(r: 0.2, g: 0.3, b: 0.85), RGBAColor(r: 0.2, g: 0.7, b: 0.3)]
        var files: [URL] = []
        for (index, color) in colors.enumerated() {
            let url = root.appendingPathComponent("video\(index + 1).mov")
            try await SampleMedia.writeTestVideo(to: url, width: 540, height: 960, seconds: 3, color: color, label: "V\(index + 1)")
            files.append(url)
        }
        let music = root.appendingPathComponent("music.wav")
        try SampleMedia.writeTone(to: music, frequency: 262, seconds: 10)
        files.append(music)

        // Create a 9:16, 1080×1920, 30 fps project and import three videos and one audio track.
        let session = try ProjectSession.create(at: root.appendingPathComponent("My Reel"), name: "My Reel",
                                                canvas: CanvasSettings(width: 1080, height: 1920, frameRate: .fps30))
        #expect(session.package.url.pathExtension == "kirie")
        let imported = try await session.importFiles(files)
        #expect(imported.assets.count == 4 && imported.failures.isEmpty)
        #expect(imported.assets.allSatisfy { !$0.reference.fingerprint.isEmpty })

        // Arrange, trim, split.
        var clips: [UUID] = []
        for asset in session.project.assets where asset.kind == .video {
            let id = UUID()
            try session.execute(.addClip(sequenceID: nil, clipID: id, assetID: asset.id, trackID: nil, start: nil, sourceStart: nil, duration: nil, index: nil))
            clips.append(id)
        }
        try session.execute(.moveClip(clipID: clips[2], toTrackID: nil, start: nil, index: 0))       // green first
        try session.execute(.trimClip(clipID: clips[0], edge: .end, to: s(3 + 1.5)))                 // red: 1.5 s
        let tail = UUID()
        try session.execute(.splitClip(clipID: clips[1], at: s(4.5 + 1), newClipID: tail))           // blue split at 1 s
        try session.execute(.removeClips(clipIDs: [tail], ripple: true))                             // drop its tail
        #expect(session.project.activeSequence.duration == s(5.5))

        // Title, caption, transition, music.
        var title = Clip(kind: .text, name: "Title", start: .zero, duration: s(2), text: TextContent(string: "MY REEL", style: TextStyle(fontSize: 150, shadow: nil)))
        title.transform.position = UnitPoint2D(x: 0.5, y: 0.15)
        try session.execute(.insertClip(sequenceID: nil, trackID: nil, clip: title, index: nil))
        try session.execute(.replaceCaptions(sequenceID: nil, trackID: UUID(), segments: [CaptionSegment(start: s(3), end: s(5), text: "A caption")],
                                             style: .caption, animation: .none))
        try session.execute(.setTransition(clipID: clips[0], transition: Transition(type: .dissolve, duration: s(0.5))))
        let song = try #require(session.project.assets.first { $0.kind == .audio })
        try session.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: song.id, trackID: nil, start: .zero, sourceStart: nil, duration: s(5), index: nil))
        #expect(session.project.activeSequence.duration == s(5))
        try session.save()

        // Export H.264 at the real Reels size and verify the output file.
        let preset = try #require(ExportPreset.named("reels-h264"))
        let report = try await session.export(preset: preset)
        #expect(report.verification.passed, "\(report.verification.failures)")
        let output = URL(fileURLWithPath: report.outputPath)
        #expect(output.path.hasPrefix(session.package.exportsURL.path))
        let (kind, metadata) = try await MediaProbe.probe(output)
        #expect(kind == .video && metadata.width == 1080 && metadata.height == 1920 && metadata.videoCodec == "avc1" && metadata.hasAudio)
        #expect(abs(metadata.frameRate - 30) < 0.5 && abs(metadata.duration.seconds - 5) < 0.12)
        #expect(report.framesWritten == 150)
        // Green first, then red, then blue.
        let first = try await pixelAt(output, seconds: 1.5, x: 0.5, y: 0.85), last = try await pixelAt(output, seconds: 4.6, x: 0.5, y: 0.5)
        #expect(first.g > 0.5 && first.r < 0.4, "green clip first: \(first)")
        #expect(last.b > 0.6 && last.r < 0.4, "blue clip last: \(last)")

        // Reopening gives back exactly the saved project.
        let reopened = try ProjectSession.open(session.package.url)
        #expect(reopened.session.project == session.project)
        #expect(reopened.opened.missingAssets.isEmpty)
    }

    // Scenario 2
    @Test func beatSyncMontage() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let musicURL = root.appendingPathComponent("beat.wav")
        try SampleMedia.writeClickTrack(to: musicURL, bpm: 120, seconds: 12, firstBeat: 0.25)
        var files = [musicURL]
        for (index, tone) in [0.3, 0.5, 0.7, 0.9].enumerated() {
            let url = root.appendingPathComponent("photo\(index + 1).png")
            try SampleMedia.writeStill(to: url, color: RGBAColor(r: tone, g: 0.4, b: 1 - tone), label: "")
            files.append(url)
        }
        let session = try ProjectSession.create(at: root.appendingPathComponent("Montage"), name: "Montage", canvas: CanvasSettings(width: 1080, height: 1920))
        try await session.importFiles(files)
        let music = try #require(session.project.assets.first { $0.kind == .audio })
        let musicClip = UUID()
        try session.execute(.addClip(sequenceID: nil, clipID: musicClip, assetID: music.id, trackID: nil, start: .zero, sourceStart: nil, duration: nil, index: nil))

        // Detect beats and review the markers.
        let (command, analysis) = try await session.beatMarkersCommand(forClip: musicClip)
        #expect(abs(analysis.bpm - 120) < 1.5)
        try session.execute(command)
        let beats = session.project.activeSequence.beatTimes
        #expect(beats.count >= 20)
        #expect(session.project.activeSequence.markers.contains { $0.kind == .downbeat })
        // The user corrects one marker; it is an ordinary, undoable edit.
        let marker = try #require(session.project.activeSequence.markers.first)
        try session.execute(.moveMarker(markerID: marker.id, to: s(0.25)))
        try session.engine.undo()
        try session.engine.redo()

        // Place the stills and cut them on every second beat.
        var stills: [UUID] = []
        for asset in session.project.assets where asset.kind == .image {
            let id = UUID()
            try session.execute(.addClip(sequenceID: nil, clipID: id, assetID: asset.id, trackID: nil, start: nil, sourceStart: nil, duration: nil, index: nil))
            stills.append(id)
        }
        try session.execute(.cutToBeat(clipIDs: stills, every: 2))
        let starts = try #require(session.project.activeSequence.mainTrack).clips.map(\.start.seconds)
        // After the first still, every cut lands on a detected beat, one second (two beats) apart.
        for start in starts.dropFirst() {
            let nearest = beats.map { abs($0.seconds - start) }.min() ?? 1
            #expect(nearest < 1.0 / 30, "cut at \(start) is \(nearest)s from a beat")
        }
        for (a, b) in zip(starts.dropFirst(), starts.dropFirst(2)) { #expect(abs((b - a) - 1.0) < 0.05) }
        // One undo restores the uncut timeline.
        try session.engine.undo()
        #expect(try #require(session.project.activeSequence.mainTrack).clips.allSatisfy { $0.duration == s(3) })
        try session.engine.redo()

        let report = try await session.export(preset: smallPreset, to: root.appendingPathComponent("montage.mp4"))
        #expect(report.verification.passed && report.hasAudio)
    }

    // Scenarios 3 and 5
    @Test func comicStripReelAndExportLock() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let stripURL = root.appendingPathComponent("strip.png")
        let truth = try SampleMedia.writeComicStrip(to: stripURL)
        let session = try ProjectSession.create(at: root.appendingPathComponent("042 beach day"), name: "Beach day", canvas: CanvasSettings(width: 1080, height: 1920))
        try await session.importFiles([stripURL])
        let asset = try #require(session.project.assets.first)

        // Import a strip with unequal panels and detect them.
        let strip = try session.addStrip(assetID: asset.id, number: 42, slug: "beach day")
        #expect(session.project.comic?.folderName == "042_beach_day")
        #expect(strip.panels.count == truth.count)
        #expect(strip.panels.allSatisfy { $0.subject != nil })
        #expect(try session.framingPlans(stripID: strip.id).allSatisfy(\.subjectSafe), "every panel passes the crop-safety check")

        // Manually correct a panel and the reading order.
        var panels = strip.panels
        panels[0].rect = UnitRect(x: 0.045, y: 0.032, width: 0.91, height: 0.266)
        panels.swapAt(1, 2)
        try session.execute(.comic(.setPanels(stripID: strip.id, panels: panels, paperColor: nil)))
        try session.refreshSubjects(stripID: strip.id)
        #expect(session.project.comic?.strips[0].panels[1].id == strip.panels[2].id)

        // Build the reel: full-screen panels with gentle motion, the full strip at the end.
        let sequence = try session.buildStripReel(stripID: strip.id)
        #expect(session.project.activeSequenceID == sequence.id)
        let reel = try #require(sequence.mainTrack).clips
        #expect(reel.count == truth.count + 1 && reel.last?.name == "Full strip")
        #expect(reel.dropLast().allSatisfy { $0.hasKeyframes(for: .scale) })
        // Rebuilding replaces the same timeline instead of piling up copies.
        try session.buildStripReel(stripID: strip.id, options: StripReelOptions(varyTransitions: true))
        #expect(session.project.sequences.count == 2)

        // Contact-sheet QA.
        let sheet = try session.contactSheet(stripID: strip.id)
        #expect(sheet.width > 500 && sheet.height > 500)
        let built = try await session.buildComposition(outputSize: CGSize(width: 270, height: 480))
        let reelSheet = try await ComicSheets.reelContactSheet(built: built, frames: 8)
        #expect(reelSheet?.width == 1140)

        // Export is locked until the strip passes QA.
        var lock = session.exportLock()
        #expect(lock.isLocked)
        await #expect(throws: RenderError.self) { try await session.export(preset: smallPreset, to: root.appendingPathComponent("locked.mp4")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("locked.mp4").path))
        #expect(throws: RenderError.self) { try session.exportCarousel(stripID: strip.id) }
        #expect(throws: EditError.self) { try session.approveStrip(stripID: strip.id, approvedBy: "reviewer") }

        let current = try #require(session.project.comic?.strips.first)
        for (index, panel) in current.panels.enumerated() {
            try session.execute(.comic(.setPanelReview(stripID: strip.id, panelID: panel.id,
                                                       review: PanelReview(status: .pass, strangerNote: "A figure stands on a tinted background, panel \(index + 1)."))))
        }
        for item in session.project.comic?.checklist.items ?? [] {
            try session.execute(.comic(.setCheck(stripID: strip.id, itemID: item.id, result: CheckResult(status: .pass, reason: "Checked at full size."))))
        }
        try session.approveStrip(stripID: strip.id, approvedBy: "reviewer")
        let approval = try #require(session.project.comic?.strips.first?.approval)
        #expect(approval.imageHash == (try FileHasher.sha256(of: stripURL)))
        #expect(approval.approvedBy == "reviewer")
        lock = session.exportLock()
        #expect(!lock.isLocked)

        let report = try await session.export(preset: smallPreset, to: root.appendingPathComponent("reel.mp4"))
        #expect(report.verification.passed)
        let expected = session.project.activeSequence.duration.seconds
        #expect(abs(report.durationSeconds - expected) < 1e-9)
        // Panel 1 (blue tint) fills the frame at the start; the page colour shows around the full strip at the end.
        let panelOne = try await pixelAt(URL(fileURLWithPath: report.outputPath), seconds: 1, x: 0.5, y: 0.47)
        #expect(abs(panelOne.r - 0.72) < 0.12 && abs(panelOne.b - 0.93) < 0.12, "panel 1 tint: \(panelOne)")
        let slides = try session.exportCarousel(stripID: strip.id)
        #expect(slides.count == truth.count + 1)

        // Scenario 5: the approved image changes on disk. The PASS no longer authorises export.
        try session.save()
        try SampleMedia.writeComicStrip(to: stripURL, paper: RGBAColor(r: 0.9, g: 0.95, b: 0.9))
        lock = session.exportLock()
        #expect(lock.isLocked && lock.strips.first?.state == .staleImage)
        await #expect(throws: RenderError.exportLocked(lock.reasons)) { try await session.export(preset: smallPreset, to: root.appendingPathComponent("stale.mp4")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stale.mp4").path))
        // The lock survives a restart: it is derived from the file, not from session state.
        #expect(try ProjectSession.open(session.package.url).session.exportLock().isLocked)

        // The rejected attempt is kept with its failing check, and re-review unlocks export.
        let attempt = try session.recordRejection(stripID: strip.id, imageURL: stripURL, failedChecks: ["G"], note: "Paper tone drifted.")
        #expect(attempt.fileName.contains("__FAIL-G__"))
        #expect(FileManager.default.fileExists(atPath: session.package.comicURL.appendingPathComponent("rejected/\(attempt.fileName)").path))
        #expect(try session.attemptStatus(stripID: strip.id).used == 2)
        try session.approveStrip(stripID: strip.id, approvedBy: "reviewer")
        #expect(!session.exportLock().isLocked)
    }

    // Scenario 4
    @Test func lyricEdit() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let songURL = root.appendingPathComponent("owned song.wav")
        try SampleMedia.writeClickTrack(to: songURL, bpm: 100, seconds: 8)
        let paper = RGBAColor(r: 0.96, g: 0.93, b: 0.86)
        var files = [songURL]
        for index in 1...2 {
            let url = root.appendingPathComponent("art\(index).png")
            try SampleMedia.writeStill(to: url, color: paper, label: "")
            files.append(url)
        }
        let session = try ProjectSession.create(at: root.appendingPathComponent("Lyric"), name: "Lyric", canvas: CanvasSettings(width: 1080, height: 1920))
        try await session.importFiles(files)
        let song = try #require(session.project.assets.first { $0.kind == .audio })
        try session.execute(.updateAssetInfo(assetID: song.id, name: nil, rights: RightsInfo(status: .owned), favourite: nil, rating: nil, keywords: nil, bpm: nil))
        let art = session.project.assets.filter { $0.kind == .image }
        try session.execute(.comic(.enable(number: 15, slug: "lyric")))

        // Lines with markup; the second line's words were tapped in by hand.
        let lines = [
            LyricLine(start: s(1), end: s(4), text: "one two *three*", style: .verse, shots: [LyricShot(at: s(1), assetID: art[0].id)], hold: 0.5),
            LyricLine(start: s(4), end: s(7), text: "tap / *tap*", style: .chorus, shots: [LyricShot(at: s(4), assetID: art[1].id)],
                      wordTimes: [s(4.5), s(6)], hold: 0.3),
        ]
        try session.execute(.comic(.setLyricEdit(edit: LyricEdit(audioAssetID: song.id, lines: lines, letterJitter: false, chorusFlash: false, punchIn: false))))
        let sequence = try session.buildLyricEdit()
        let lettering = try #require(sequence.tracks.first { $0.name == "Lyrics" }).clips
        // Line 1: three words spread across 3 s minus a 0.5 s hold. Line 2: exactly the tapped times.
        #expect(lettering[0].text?.lyric?.wordTimes.map(\.seconds).map { ($0 * 1000).rounded() / 1000 } == [0, 0.833, 1.667])
        #expect(lettering[1].text?.lyric?.wordTimes == [s(0.5), s(2)])
        #expect(sequence.duration == s(8))

        let output = root.appendingPathComponent("lyric.mp4")
        let report = try await session.export(preset: smallPreset, to: output)
        #expect(report.verification.passed && report.hasAudio)
        #expect(abs(report.durationSeconds - 8) < 1e-9)

        // Timing check on the exported pixels: count lettering in the top band at chosen moments.
        func ink(_ seconds: Double) async throws -> Int {
            // Grab the frame once, then count lettering pixels in the top band.
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var count = 0
            for y in stride(from: Int(Double(height) * 0.06), to: Int(Double(height) * 0.30), by: 4) {
                for x in stride(from: Int(Double(width) * 0.04), to: Int(Double(width) * 0.96), by: 4) {
                    let offset = (y * width + x) * 4
                    let r = Double(bytes[offset]) / 255, g = Double(bytes[offset + 1]) / 255, b = Double(bytes[offset + 2]) / 255
                    if abs(r - paper.r) > 0.2 || abs(g - paper.g) > 0.2 || abs(b - paper.b) > 0.2 { count += 1 }
                }
            }
            return count
        }
        #expect(try await ink(0.5) == 0, "nothing before the first line starts")
        let oneWord = try await ink(1.5), threeWords = try await ink(3.6)
        #expect(oneWord > 0 && threeWords > oneWord, "words accumulate: \(oneWord) → \(threeWords)")
        let beforeTap = try await ink(4.25), firstTap = try await ink(5.2), secondTap = try await ink(6.6)
        #expect(beforeTap == 0, "the tapped word has not arrived at 4.25 s")
        #expect(firstTap > 0 && secondTap > firstTap, "tapped words arrive at 4.5 s and 6 s: \(firstTap) → \(secondTap)")
        #expect(try await ink(7.6) == 0, "the line has left")
    }

    // Scenario 6
    @Test func recoveryAfterInterruptedSave() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try ProjectSession.create(at: root.appendingPathComponent("Recover"), name: "Recover", canvas: CanvasSettings(width: 1080, height: 1920))
        let still = root.appendingPathComponent("still.png")
        try SampleMedia.writeStill(to: still, color: .paper, label: "")
        try await session.importFiles([still])
        let asset = try #require(session.project.assets.first)
        for _ in 0..<3 {
            try session.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: asset.id, trackID: nil, start: nil, sourceStart: nil, duration: nil, index: nil))
        }
        #expect(session.hasUnsavedChanges)
        try session.save()
        #expect(!session.hasUnsavedChanges)
        let consistent = session.project

        // The app is force-quit halfway through the next autosave: a truncated temporary file is left behind.
        try session.execute(.renameProject(name: "Edit that never finished saving"))
        let encoded = try ProjectCodec.encode(session.project)
        try encoded.prefix(encoded.count / 2).write(to: session.package.url.appendingPathComponent("project.json\(AtomicFile.temporaryMarker)crash"))

        let (recovered, opened) = try ProjectSession.open(session.package.url)
        #expect(recovered.project == consistent, "the latest complete save is restored")
        #expect(opened.removedTemporaryFiles == 1)

        // Worse: project.json itself is destroyed. The newest snapshot is used and the user is told.
        try recovered.createSnapshot(name: "Good state")
        try Data(count: 64).write(to: recovered.package.projectURL)
        let (fromSnapshot, second) = try ProjectSession.open(recovered.package.url)
        #expect(fromSnapshot.project == consistent)
        guard case .recoveredFromSnapshot(let info, _) = second.source else { Issue.record("expected snapshot recovery"); return }
        #expect(info.name == "Good state")
        // Recovery rewrites project.json, so the next open is normal again.
        #expect(try ProjectSession.open(recovered.package.url).opened.source == .saved)

        // Restoring a prior snapshot is itself reversible.
        try fromSnapshot.execute(.renameProject(name: "Later"))
        try fromSnapshot.save()
        let good = try #require(fromSnapshot.package.listSnapshots().first { $0.name == "Good state" })
        try fromSnapshot.restoreSnapshot(good)
        #expect(fromSnapshot.project.name == "Recover")
        #expect(fromSnapshot.package.listSnapshots().contains { $0.name == "Before restore" && $0.automatic })
    }

    // Scenario 7
    @Test func portableProject() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaFolder = root.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        try await SampleMedia.writeTestVideo(to: mediaFolder.appendingPathComponent("clip.mov"), width: 360, height: 640, seconds: 2,
                                             color: RGBAColor(r: 0.8, g: 0.3, b: 0.2), label: "P", toneFrequency: 300)
        try SampleMedia.writeStill(to: mediaFolder.appendingPathComponent("photo.png"), color: .paper, label: "")
        let session = try ProjectSession.create(at: root.appendingPathComponent("Portable"), name: "Portable", canvas: CanvasSettings(width: 1080, height: 1920))
        let imported = try await session.importFiles([mediaFolder])
        #expect(imported.assets.count == 2, "importing a folder imports the media inside it")
        for asset in session.project.assets {
            try session.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: asset.id, trackID: nil, start: nil, sourceStart: nil, duration: nil, index: nil))
        }
        // Collect media into the package, then move the package and delete the originals.
        let report = try session.collectMedia()
        #expect(report.copied == 2 && report.missing.isEmpty)
        let moved = root.appendingPathComponent("Another Disk/Portable.kirie")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: session.package.url, to: moved)
        try FileManager.default.removeItem(at: mediaFolder)

        let (reopened, opened) = try ProjectSession.open(moved)
        #expect(opened.missingAssets.isEmpty, "all media links survive the move")
        #expect(reopened.project.assets.allSatisfy { $0.reference.relativePath?.hasPrefix("Media/") == true })
        let export = try await reopened.export(preset: smallPreset)
        #expect(export.verification.passed && export.hasAudio)
        #expect(export.outputPath.hasPrefix(moved.path))
    }

    @Test func missingMediaCanBeRelinked() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("clip.mov")
        try await SampleMedia.writeTestVideo(to: original, width: 360, height: 640, seconds: 2, color: RGBAColor(r: 0.2, g: 0.6, b: 0.6), label: "R")
        let session = try ProjectSession.create(at: root.appendingPathComponent("Relink"), name: "Relink", canvas: CanvasSettings(width: 1080, height: 1920))
        try await session.importFiles([original])
        let asset = try #require(session.project.assets.first)
        try session.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: asset.id, trackID: nil, start: nil, sourceStart: nil, duration: nil, index: nil))
        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let moved = archive.appendingPathComponent("renamed clip.mov")
        try FileManager.default.moveItem(at: original, to: moved)

        #expect(session.package.missingAssets(in: session.project).count == 1)
        await #expect(throws: RenderError.missingMedia(["clip.mov"])) { try await session.export(preset: smallPreset) }
        // Kirie suggests the moved file by content; the user confirms.
        let suggestion = try #require(RelinkFinder.candidates(for: asset, in: root).first)
        #expect(suggestion.url.lastPathComponent == "renamed clip.mov" && suggestion.reasons.contains("same content"))
        try await session.relink(assetID: asset.id, to: suggestion.url)
        #expect(session.package.missingAssets(in: session.project).isEmpty)
        #expect(try await session.export(preset: smallPreset).verification.passed)

        // A file of the wrong length is refused rather than silently accepted.
        let short = root.appendingPathComponent("short.mov")
        try await SampleMedia.writeTestVideo(to: short, width: 360, height: 640, seconds: 1, color: .black, label: "S")
        await #expect(throws: ServiceError.self) { try await session.relink(assetID: asset.id, to: short) }
    }

    @Test func captionFilesRoundTripThroughTheTimeline() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try ProjectSession.create(at: root.appendingPathComponent("Captions"), name: "Captions", canvas: CanvasSettings(width: 1080, height: 1920))
        try session.execute(.insertClip(sequenceID: nil, trackID: nil, clip: Clip(kind: .solid, duration: s(10), solidColor: .black), index: nil))
        let srt = root.appendingPathComponent("captions.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nFirst line\n\n2\n00:00:03,000 --> 00:00:05,000\nSecond line\n".write(to: srt, atomically: true, encoding: .utf8)
        try session.execute(try session.captionsCommand(fromSubtitleFile: srt))
        #expect(ProjectSession.captionSegments(in: session.project.activeSequence).map(\.text) == ["First line", "Second line"])
        #expect(session.exportCaptions(format: .srt).contains("00:00:03,000 --> 00:00:05,000\nSecond line"))
        #expect(session.exportCaptions(format: .vtt).hasPrefix("WEBVTT"))
        #expect(session.exportCaptions(format: .lrc).contains("[00:01.00]First line"))
        let lrc = root.appendingPathComponent("lyrics.lrc")
        try "[00:02.00]Line A\n[00:06.00]Line B\n".write(to: lrc, atomically: true, encoding: .utf8)
        try session.execute(try session.captionsCommand(fromSubtitleFile: lrc))
        let segments = ProjectSession.captionSegments(in: session.project.activeSequence)
        #expect(segments.map(\.text) == ["Line A", "Line B"] && segments[1].end == s(10), "the last LRC line runs to the end of the timeline")
        #expect(throws: ServiceError.self) { try session.captionsCommand(fromSubtitleFile: root.appendingPathComponent("notes.txt")) }
    }

    @Test func spokenWordsGroupIntoReadableCaptions() {
        func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord { TimedWord(text: text, start: s(start), end: s(end)) }
        let words = [word("Hello", 0, 0.4), word("there.", 0.4, 0.8), word("This", 0.9, 1.1), word("is", 1.1, 1.2), word("Kirie", 1.2, 1.6),
                     word("after", 3.0, 3.3), word("a", 3.3, 3.4), word("pause", 3.4, 3.8)]
        let captions = SpeechTranscriber.group(words)
        #expect(captions.map(\.text) == ["Hello there.", "This is Kirie", "after a pause"])
        #expect(captions[1].start == s(0.9) && captions[1].end == s(1.6) && captions[1].words.count == 3)
        let long = (0..<20).map { word("w\($0)", Double($0) * 0.2, Double($0) * 0.2 + 0.2) }
        #expect(SpeechTranscriber.group(long, maxWords: 7).allSatisfy { $0.words.count <= 7 })
    }

    @Test func demoProjectBuildsOpensAndExports() async throws {
        let root = try scenarioFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = try await DemoBuilder.build(in: root)
        #expect(demo.sequences == ["Reel", "Strip reel", "Lyric edit"])
        let (session, opened) = try ProjectSession.open(demo.projectURL)
        #expect(opened.missingAssets.isEmpty && opened.source == .saved)
        #expect(ProjectValidator.validate(session.project).isEmpty)
        #expect(!session.exportLock().isLocked, "the demo strip is reviewed and approved")
        #expect(session.package.listSnapshots().contains { $0.name == "Fresh demo" })
        for sequence in session.project.sequences {
            let report = try await session.export(preset: smallPreset, to: root.appendingPathComponent("\(sequence.name).mp4"), sequenceID: sequence.id)
            #expect(report.verification.passed, "\(sequence.name): \(report.verification.failures)")
            #expect(abs(report.durationSeconds - sequence.duration.seconds) < 1e-9)
        }
        await #expect(throws: PersistenceError.self) { try await DemoBuilder.build(in: root) }
    }

    // Scenario 9
    @Test func noNetworkCodeInTheLocalEditor() throws {
        // Kirie's local editor must work with no account and no network. The simplest guarantee is
        // that the code contains no networking at all, so guard that here.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let forbidden = ["URLSession", "NWConnection", "CFNetwork", "URLRequest(", "http://", "https://", "import Network"]
        var offenders: [String] = []
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden where text.contains(token) { offenders.append("\(file.lastPathComponent): \(token)") }
        }
        #expect(scanned > 30)
        #expect(offenders.isEmpty, "network code found: \(offenders)")
    }
}
