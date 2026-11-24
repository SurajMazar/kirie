import Foundation
import Testing
@testable import ProjectDomain

@Suite("Timeline commands")
struct CommandTests {
    @Test func mainTrackIsMagnetic() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        let b = try Fixture.add(&engine, assets[1])
        let c = try Fixture.add(&engine, assets[2])
        #expect(engine.main.map(\.id) == [a, b, c])
        #expect(engine.main.map(\.start) == [seconds(0), seconds(10), seconds(18)])
        #expect(engine.project.activeSequence.duration == seconds(24))

        // Ripple delete closes the gap.
        try engine.execute(.removeClips(clipIDs: [b], ripple: true))
        #expect(engine.main.map(\.start) == [seconds(0), seconds(10)])

        // Reorder.
        try engine.execute(.moveClip(clipID: c, toTrackID: nil, start: nil, index: 0))
        #expect(engine.main.map(\.id) == [c, a])
        #expect(engine.main.map(\.start) == [seconds(0), seconds(6)])
    }

    @Test func splitKeepsSourceContinuous() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        let second = UUID()
        try engine.execute(.splitClip(clipID: a, at: seconds(4), newClipID: second))
        let clips = engine.main
        #expect(clips.count == 2)
        #expect(clips[0].duration == seconds(4))
        #expect(clips[1].start == seconds(4))
        #expect(clips[1].sourceStart == seconds(4))
        #expect(clips[1].duration == seconds(6))
        #expect(throws: EditError.self) { try engine.execute(.splitClip(clipID: a, at: seconds(0), newClipID: UUID())) }
        #expect(throws: EditError.self) { try engine.execute(.splitClip(clipID: a, at: seconds(99), newClipID: UUID())) }
    }

    @Test func splitKeepsKeyframedMotionContinuous() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        try engine.execute(.setKeyframe(clipID: a, keyframe: Keyframe(property: .scale, time: .zero, value: 1, easing: .linear)))
        try engine.execute(.setKeyframe(clipID: a, keyframe: Keyframe(property: .scale, time: seconds(10), value: 2, easing: .linear)))
        let second = UUID()
        try engine.execute(.splitClip(clipID: a, at: seconds(5), newClipID: second))
        let clips = engine.main
        #expect(abs(clips[0].value(of: .scale, at: seconds(5)) - 1.5) < 1e-9)
        #expect(abs(clips[1].value(of: .scale, at: .zero) - 1.5) < 1e-9)
        #expect(abs(clips[1].value(of: .scale, at: seconds(5)) - 2) < 1e-9)
    }

    @Test func trimRespectsSourceLimits() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        let b = try Fixture.add(&engine, assets[1])
        try engine.execute(.trimClip(clipID: a, edge: .end, to: seconds(6)))
        #expect(engine.main[0].duration == seconds(6))
        #expect(engine.main[1].start == seconds(6), "the next clip ripples")

        // Trim the head in by 2 s: source advances, clip shortens.
        try engine.execute(.trimClip(clipID: b, edge: .start, to: seconds(8)))
        #expect(engine.main[1].sourceStart == seconds(2))
        #expect(engine.main[1].duration == seconds(6))

        // Cannot extend past the media.
        try engine.execute(.trimClip(clipID: a, edge: .end, to: seconds(500)))
        #expect(engine.main[0].duration == seconds(10))
        // Cannot extend the head before the media begins.
        try engine.execute(.trimClip(clipID: a, edge: .start, to: seconds(-5)))
        #expect(engine.main[0].sourceStart == .zero)
        #expect(engine.main[0].duration == seconds(10))
    }

    @Test func transitionsOverlapNeighbours() throws {
        var (engine, assets) = Fixture.stocked()
        _ = try Fixture.add(&engine, assets[0])
        let b = try Fixture.add(&engine, assets[1])
        try engine.execute(.setTransition(clipID: b, transition: Transition(type: .dissolve, duration: seconds(1))))
        #expect(engine.main[1].start == seconds(9))
        #expect(engine.project.activeSequence.duration == seconds(17))

        // A transition can never be longer than half the shorter neighbour.
        try engine.execute(.setTransition(clipID: b, transition: Transition(type: .pageFold, duration: seconds(60))))
        #expect(engine.main[1].transitionIn?.duration == seconds(4))
        try engine.execute(.setTransition(clipID: b, transition: nil))
        #expect(engine.main[1].start == seconds(10))
    }

    @Test func freeTracksRejectOverlaps() throws {
        var (engine, assets) = Fixture.stocked()
        let track = UUID()
        try engine.execute(.addTrack(sequenceID: nil, trackID: track, kind: .overlay, name: nil, index: nil))
        let first = try Fixture.add(&engine, assets[3], trackID: track, start: seconds(1), duration: seconds(3))
        #expect(throws: EditError.self) {
            try Fixture.add(&engine, assets[3], trackID: track, start: seconds(2), duration: seconds(3))
        }
        let second = try Fixture.add(&engine, assets[3], trackID: track, start: seconds(4), duration: seconds(2))
        #expect(throws: EditError.self) {
            try engine.execute(.moveClip(clipID: second, toTrackID: track, start: seconds(2), index: nil))
        }
        try engine.execute(.moveClip(clipID: second, toTrackID: track, start: seconds(8), index: nil))
        #expect(engine.project.activeSequence.clip(second)?.start == seconds(8))
        // Trimming the end stops at the neighbour.
        try engine.execute(.moveClip(clipID: second, toTrackID: track, start: seconds(5), index: nil))
        try engine.execute(.trimClip(clipID: first, edge: .end, to: seconds(30)))
        #expect(engine.project.activeSequence.clip(first)?.end == seconds(5))
    }

    @Test func audioGoesToAnAudioTrackAutomatically() throws {
        var (engine, assets) = Fixture.stocked()
        let song = try Fixture.add(&engine, assets[4])
        let sequence = engine.project.activeSequence
        let location = try #require(sequence.locate(song))
        #expect(sequence.tracks[location.track].kind == .audio)
        #expect(sequence.clip(song)?.duration == seconds(30))
        // A second overlapping song lands on a new audio track rather than failing.
        let other = try Fixture.add(&engine, assets[4])
        let after = engine.project.activeSequence
        #expect(after.locate(other)?.track != after.locate(song)?.track)
    }

    @Test func detachAudioLinksAndRipples() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        let b = try Fixture.add(&engine, assets[1])
        let audio = UUID()
        try engine.execute(.detachAudio(clipID: b, newClipID: audio, newTrackID: UUID()))
        var sequence = engine.project.activeSequence
        #expect(sequence.clip(b)?.audio.muted == true)
        #expect(sequence.clip(audio)?.start == seconds(10))
        #expect(sequence.clip(audio)?.linkedClipID == b)
        // Shortening the first clip pulls the linked audio along with its picture.
        try engine.execute(.trimClip(clipID: a, edge: .end, to: seconds(4)))
        sequence = engine.project.activeSequence
        #expect(sequence.clip(b)?.start == seconds(4))
        #expect(sequence.clip(audio)?.start == seconds(4))
        #expect(throws: EditError.self) { try engine.execute(.detachAudio(clipID: b, newClipID: UUID(), newTrackID: UUID())) }
    }

    @Test func speedChangesDurationNotSource() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        try engine.execute(.setSpeed(clipID: a, speed: 2))
        #expect(engine.main[0].duration == seconds(5))
        #expect(abs(engine.main[0].sourceDuration.seconds - 10) < 1e-6)
        try engine.execute(.setSpeed(clipID: a, speed: 0.5))
        #expect(engine.main[0].duration == seconds(20))
        #expect(throws: EditError.self) { try engine.execute(.setSpeed(clipID: a, speed: 0)) }
        #expect(throws: EditError.self) { try engine.execute(.setSpeed(clipID: a, speed: .nan)) }
    }

    @Test func stillsGetADefaultLengthAndAnyDuration() throws {
        var (engine, assets) = Fixture.stocked()
        let still = try Fixture.add(&engine, assets[3])
        #expect(engine.main[0].duration == seconds(3))
        try engine.execute(.trimClip(clipID: still, edge: .end, to: seconds(45)))
        #expect(engine.main[0].duration == seconds(45))
    }

    @Test func cutToBeatLandsCutsOnBeats() throws {
        var (engine, assets) = Fixture.stocked()
        var ids: [UUID] = []
        for _ in 0..<4 { ids.append(try Fixture.add(&engine, assets[3])) }
        // 120 BPM: a beat every 0.5 s.
        let beats = (0..<40).map { Marker(time: seconds(Double($0) * 0.5), kind: $0 % 4 == 0 ? .downbeat : .beat) }
        try engine.execute(.replaceBeatMarkers(sequenceID: nil, markers: beats))
        try engine.execute(.cutToBeat(clipIDs: ids, every: 2))
        #expect(engine.main.map(\.start) == [seconds(0), seconds(1), seconds(2), seconds(3)])
        #expect(engine.main.map(\.duration) == Array(repeating: seconds(1), count: 4))

        // With a dissolve, the incoming clip still starts on the beat.
        try engine.execute(.setTransition(clipID: ids[1], transition: Transition(type: .dissolve, duration: seconds(0.2))))
        try engine.execute(.cutToBeat(clipIDs: ids, every: 2))
        #expect(engine.main.map(\.start) == [seconds(0), seconds(1), seconds(2), seconds(3)])
        #expect(engine.main[0].duration == seconds(1.2))

        // A video that is too short to reach the next beat is reported, not silently mis-cut.
        var (short, shortAssets) = Fixture.stocked()
        let clip = try Fixture.add(&short, shortAssets[2])
        try short.execute(.replaceBeatMarkers(sequenceID: nil, markers: [Marker(time: seconds(20), kind: .beat)]))
        #expect(throws: EditError.self) { try short.execute(.cutToBeat(clipIDs: [clip], every: 1)) }
    }

    @Test func captionsReplaceAsOneTrack() throws {
        var (engine, _) = Fixture.stocked()
        let track = UUID()
        let segments = [CaptionSegment(start: seconds(0.5), end: seconds(2), text: "Hello there",
                                       words: [TimedWord(text: "Hello", start: seconds(0.5), end: seconds(1)),
                                               TimedWord(text: "there", start: seconds(1), end: seconds(2))]),
                        CaptionSegment(start: seconds(1.8), end: seconds(4), text: "Overlap is trimmed"),
                        CaptionSegment(start: seconds(5), end: seconds(5), text: "zero length is dropped")]
        try engine.execute(.replaceCaptions(sequenceID: nil, trackID: track, segments: segments, style: .caption, animation: .karaoke))
        let captions = try #require(engine.project.activeSequence.track(track))
        #expect(captions.kind == .caption)
        #expect(captions.clips.count == 2)
        #expect(captions.clips[0].end <= captions.clips[1].start)
        #expect(captions.clips[0].text?.words.first?.start == .zero, "word times are stored relative to the clip")
        try engine.execute(.replaceCaptions(sequenceID: nil, trackID: track, segments: [], style: .caption, animation: .none))
        #expect(engine.project.activeSequence.track(track)?.clips.isEmpty == true)
    }

    @Test func lockedTracksRefuseEdits() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        let main = try #require(engine.project.activeSequence.mainTrack)
        try engine.execute(.setTrackState(trackID: main.id, muted: nil, hidden: nil, locked: true, gain: nil, name: nil))
        #expect(throws: EditError.trackLocked("Main")) { try engine.execute(.removeClips(clipIDs: [a], ripple: true)) }
        #expect(throws: EditError.self) { try engine.execute(.splitClip(clipID: a, at: seconds(2), newClipID: UUID())) }
    }

    @Test func assetsInUseCannotBeRemoved() throws {
        var (engine, assets) = Fixture.stocked()
        _ = try Fixture.add(&engine, assets[0])
        #expect(throws: EditError.assetInUse("a.mov")) { try engine.execute(.removeAsset(assetID: assets[0].id)) }
        try engine.execute(.removeAsset(assetID: assets[1].id))
        #expect(engine.project.asset(assets[1].id) == nil)
    }

    @Test func keyframesInterpolate() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        try engine.execute(.setKeyframe(clipID: a, keyframe: Keyframe(property: .opacity, time: seconds(1), value: 0, easing: .linear)))
        try engine.execute(.setKeyframe(clipID: a, keyframe: Keyframe(property: .opacity, time: seconds(3), value: 1, easing: .linear)))
        let clip = engine.main[0]
        #expect(clip.value(of: .opacity, at: .zero) == 0)
        #expect(abs(clip.value(of: .opacity, at: seconds(2)) - 0.5) < 1e-9)
        #expect(clip.value(of: .opacity, at: seconds(9)) == 1)
        #expect(clip.value(of: .scale, at: seconds(2)) == 1, "un-keyframed properties use the base value")
        // Setting a keyframe at the same time replaces it.
        try engine.execute(.setKeyframe(clipID: a, keyframe: Keyframe(property: .opacity, time: seconds(3), value: 0.4, easing: .linear)))
        #expect(engine.main[0].keyframes.count == 2)
    }

    @Test func commandsSerialiseToStableJSON() throws {
        let clip = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let command = EditCommand.splitClip(clipID: clip, at: RationalTime(3, 2), newClipID: clip)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(command), as: UTF8.self)
        #expect(json == "{\"splitClip\":{\"at\":\"3/2\",\"clipID\":\"11111111-2222-3333-4444-555555555555\",\"newClipID\":\"11111111-2222-3333-4444-555555555555\"}}")
        #expect(try JSONDecoder().decode(EditCommand.self, from: Data(json.utf8)) == command)
        #expect(command.name == "splitClip")
    }
}

@Suite("Undo, redo and history")
struct HistoryTests {
    @Test func undoAndRedoRestoreExactState() throws {
        var engine = CommandEngine(project: Fixture.reel())
        var states: [Project] = [engine.project]
        let assets = [Fixture.video("a.mov", duration: 10), Fixture.video("b.mov", duration: 8), Fixture.video("c.mov", duration: 6),
                      Fixture.image("still.png"), Fixture.audio("song.m4a", duration: 30)]
        try engine.execute(.importAssets(assets: assets)); states.append(engine.project)
        let a = try Fixture.add(&engine, assets[0]); states.append(engine.project)
        let b = try Fixture.add(&engine, assets[1]); states.append(engine.project)
        try engine.execute(.splitClip(clipID: a, at: seconds(3), newClipID: UUID())); states.append(engine.project)
        try engine.execute(.setTransition(clipID: b, transition: Transition(type: .slide, duration: seconds(0.5)))); states.append(engine.project)
        try engine.execute(.trimClip(clipID: b, edge: .end, to: seconds(12))); states.append(engine.project)
        _ = try Fixture.add(&engine, assets[4]); states.append(engine.project)
        try engine.execute(.detachAudio(clipID: b, newClipID: UUID(), newTrackID: UUID())); states.append(engine.project)
        try engine.execute(.removeClips(clipIDs: [a], ripple: true)); states.append(engine.project)
        try engine.execute(.comic(command: .enable(number: 7, slug: "Beach day"))); states.append(engine.project)
        try engine.execute(.renameProject(name: "Renamed")); states.append(engine.project)

        func same(_ x: Project, _ y: Project) -> Bool {
            var x = x, y = y
            x.modifiedAt = Date(timeIntervalSince1970: 0); y.modifiedAt = x.modifiedAt
            return x == y
        }
        for index in stride(from: states.count - 2, through: 0, by: -1) {
            try engine.undo()
            #expect(same(engine.project, states[index]), "undo to step \(index)")
        }
        #expect(!engine.canUndo)
        #expect(throws: EditError.nothingToUndo) { try engine.undo() }
        for index in 1..<states.count {
            try engine.redo()
            #expect(same(engine.project, states[index]), "redo to step \(index)")
        }
        #expect(throws: EditError.nothingToRedo) { try engine.redo() }
    }

    @Test func aFailedCommandChangesNothing() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        let before = engine.project
        let revision = engine.revision
        #expect(throws: EditError.self) {
            try engine.execute([.trimClip(clipID: a, edge: .end, to: seconds(4)),
                                .splitClip(clipID: UUID(), at: seconds(1), newClipID: UUID())], label: "Batch")
        }
        #expect(engine.project == before, "a batch is atomic")
        #expect(engine.revision == revision)
        #expect(engine.undoStack.count == 2)
    }

    @Test func groupedCommandsUndoTogether() throws {
        var (engine, assets) = Fixture.stocked()
        let ids = [UUID(), UUID()]
        try engine.execute(ids.enumerated().map { index, id in
            .addClip(sequenceID: nil, clipID: id, assetID: assets[index].id, trackID: nil, start: nil, sourceStart: nil, duration: nil, index: nil)
        }, label: "Add two clips")
        #expect(engine.main.count == 2)
        #expect(engine.undoLabel == "Add two clips")
        try engine.undo()
        #expect(engine.main.isEmpty)
    }

    @Test func sliderDragsCoalesceIntoOneUndoStep() throws {
        var (engine, assets) = Fixture.stocked()
        let a = try Fixture.add(&engine, assets[0])
        let steps = engine.undoStack.count
        for scale in stride(from: 1.0, through: 2.0, by: 0.1) {
            try engine.execute(.setTransform(clipID: a, transform: ClipTransform(scale: scale)), coalesceKey: "scale-\(a)")
        }
        #expect(engine.undoStack.count == steps + 1)
        engine.breakCoalescing()
        try engine.execute(.setTransform(clipID: a, transform: ClipTransform(scale: 3)), coalesceKey: "scale-\(a)")
        #expect(engine.undoStack.count == steps + 2)
        try engine.undo()
        #expect(abs(engine.main[0].transform.scale - 2) < 1e-9)
        try engine.undo()
        #expect(engine.main[0].transform.scale == 1)
    }

    @Test func historyIsBounded() throws {
        var (engine, _) = Fixture.stocked()
        engine.historyLimit = 5
        for index in 0..<20 { try engine.execute(.renameProject(name: "Name \(index)")) }
        #expect(engine.undoStack.count == 5)
    }

    @Test func noOpCommandsDoNotAddHistory() throws {
        var (engine, _) = Fixture.stocked()
        let steps = engine.undoStack.count
        try engine.execute(.renameProject(name: engine.project.name))
        #expect(engine.undoStack.count == steps)
    }

    @Test func dryRunLeavesProjectUntouched() throws {
        var (engine, assets) = Fixture.stocked()
        let before = engine.project
        let patch = try engine.dryRun([.addClip(sequenceID: nil, clipID: UUID(), assetID: assets[0].id, trackID: nil, start: nil,
                                                sourceStart: nil, duration: nil, index: nil)])
        #expect(!patch.isEmpty)
        #expect(engine.project == before)
        _ = try Fixture.add(&engine, assets[0])
    }
}
