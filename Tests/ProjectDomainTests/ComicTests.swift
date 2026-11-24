import Foundation
import Testing
@testable import ProjectDomain

@Suite("Comic Studio")
struct ComicTests {
    static let hashA = String(repeating: "a", count: 64)
    static let hashB = String(repeating: "b", count: 64)

    /// A comic project with one strip of three unequal panels.
    static func comic() throws -> (CommandEngine, ComicStrip, MediaAsset) {
        var engine = CommandEngine(project: Fixture.reel())
        let strip = Fixture.image("strip.png", width: 1024, height: 1536)
        try engine.execute(.importAssets(assets: [strip]))
        try engine.execute(.comic(command: .enable(number: 42, slug: "Beach Day!")))
        let panels = [ComicPanel(rect: UnitRect(x: 0.03, y: 0.02, width: 0.94, height: 0.30)),
                      ComicPanel(rect: UnitRect(x: 0.03, y: 0.34, width: 0.45, height: 0.30)),
                      ComicPanel(rect: UnitRect(x: 0.52, y: 0.34, width: 0.45, height: 0.64))]
        let model = ComicStrip(assetID: strip.id, panels: panels)
        try engine.execute(.comic(command: .addStrip(strip: model)))
        return (engine, model, strip)
    }

    static func passEverything(_ engine: inout CommandEngine, _ strip: ComicStrip) throws {
        for (index, panel) in strip.panels.enumerated() {
            try engine.execute(.comic(command: .setPanelReview(stripID: strip.id, panelID: panel.id,
                                                      review: PanelReview(status: .pass, strangerNote: "Two friends share an umbrella, panel \(index + 1)."))))
        }
        for item in QAChecklist.comicDefault.items {
            try engine.execute(.comic(command: .setCheck(stripID: strip.id, itemID: item.id, result: CheckResult(status: .pass, reason: "Checked at full size."))))
        }
    }

    static func approve(_ engine: inout CommandEngine, _ strip: ComicStrip, imageHash: String) throws {
        let comic = try #require(engine.project.comic)
        let current = try #require(comic.strip(strip.id))
        let approval = StripApproval(imageHash: imageHash, qaHash: QAGate.stateHash(strip: current, checklist: comic.checklist),
                                     approvedBy: "tester", approvedAt: Date(timeIntervalSince1970: 1_800_000_500))
        try engine.execute(.comic(command: .approveStrip(stripID: strip.id, approval: approval)))
    }

    @Test func folderNamesFollowTheNumberedConvention() throws {
        let (engine, _, _) = try Self.comic()
        #expect(engine.project.comic?.folderName == "042_beach_day")
        #expect(ComicState(number: 3, slug: "  ").folderName == "003_untitled")
    }

    @Test func approvalNeedsACompleteReview() throws {
        var (engine, strip, _) = try Self.comic()
        #expect(throws: EditError.self) { try Self.approve(&engine, strip, imageHash: Self.hashA) }
        let blockers = QAGate.approvalBlockers(strip: strip, comic: try #require(engine.project.comic))
        #expect(blockers.contains { $0.contains("Panel 1 has not been reviewed") })
        #expect(blockers.contains { $0.contains("Check A") })

        try Self.passEverything(&engine, strip)
        // A soft-pass word in a note blocks approval.
        try engine.execute(.comic(command: .setPanelReview(stripID: strip.id, panelID: strip.panels[0].id,
                                                  review: PanelReview(status: .pass, strangerNote: "Looks acceptable, mostly."))))
        #expect(throws: EditError.self) { try Self.approve(&engine, strip, imageHash: Self.hashA) }
        try engine.execute(.comic(command: .setPanelReview(stripID: strip.id, panelID: strip.panels[0].id,
                                                  review: PanelReview(status: .pass, strangerNote: "A girl hands a boy an umbrella."))))
        try Self.approve(&engine, strip, imageHash: Self.hashA)
        #expect(engine.project.comic?.strips[0].approval?.approvedBy == "tester")
    }

    @Test func exportLockFollowsTheApprovedImageAndReview() throws {
        var (engine, strip, asset) = try Self.comic()
        var lock = QAGate.exportLock(project: engine.project, imageHashes: [asset.id: Self.hashA])
        #expect(lock.isLocked)
        #expect(lock.strips.first?.state == .notApproved)

        try Self.passEverything(&engine, strip)
        try Self.approve(&engine, strip, imageHash: Self.hashA)
        lock = QAGate.exportLock(project: engine.project, imageHashes: [asset.id: Self.hashA])
        #expect(!lock.isLocked)
        #expect(lock.strips.first?.state == .approved)

        // The image changes on disk: the old PASS no longer authorises export.
        lock = QAGate.exportLock(project: engine.project, imageHashes: [asset.id: Self.hashB])
        #expect(lock.isLocked)
        #expect(lock.strips.first?.state == .staleImage)

        // The file disappears: cannot verify, so locked.
        lock = QAGate.exportLock(project: engine.project, imageHashes: [:])
        #expect(lock.strips.first?.state == .unverifiable)

        // A panel is redrawn after approval: stale review.
        var panels = strip.panels
        panels[0].rect = UnitRect(x: 0.05, y: 0.02, width: 0.9, height: 0.3)
        let current = try #require(engine.project.comic?.strip(strip.id))
        panels = zip(panels, current.panels).map { edited, live in var p = live; p.rect = edited.rect; return p }
        try engine.execute(.comic(command: .setPanels(stripID: strip.id, panels: panels, paperColor: nil)))
        lock = QAGate.exportLock(project: engine.project, imageHashes: [asset.id: Self.hashA])
        #expect(lock.strips.first?.state == .staleReview)

        // Re-approving the changed state unlocks again; turning the requirement off unlocks everything.
        try Self.approve(&engine, strip, imageHash: Self.hashA)
        #expect(!QAGate.exportLock(project: engine.project, imageHashes: [asset.id: Self.hashA]).isLocked)
        try engine.execute(.comic(command: .revokeApproval(stripID: strip.id)))
        #expect(QAGate.exportLock(project: engine.project, imageHashes: [asset.id: Self.hashA]).isLocked)
        try engine.execute(.comic(command: .setRequireQA(required: false)))
        #expect(!QAGate.exportLock(project: engine.project, imageHashes: [:]).isLocked)
    }

    @Test func approvalRejectsAStaleQAHash() throws {
        var (engine, strip, _) = try Self.comic()
        try Self.passEverything(&engine, strip)
        let stale = StripApproval(imageHash: Self.hashA, qaHash: Self.hashB, approvedBy: "tester")
        #expect(throws: EditError.self) { try engine.execute(.comic(command: .approveStrip(stripID: strip.id, approval: stale))) }
    }

    @Test func framingNeverCutsOffTheSubject() {
        // A wide panel on a tall canvas: covering would crop the sides.
        let subject = UnitRect(x: 0.05, y: 0.2, width: 0.9, height: 0.6)
        let cover = FramingPlanner.plan(pictureAspect: 2.0, canvasAspect: 9.0 / 16.0, subject: subject, focus: nil, requestedFit: .cover)
        #expect(cover.fit == .contain, "falls back to showing the whole panel")
        #expect(cover.subjectSafe)

        // A small centred subject is safe to cover.
        let small = UnitRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        let filled = FramingPlanner.plan(pictureAspect: 0.7, canvasAspect: 9.0 / 16.0, subject: small, focus: nil, requestedFit: .cover)
        #expect(filled.fit == .cover)
        #expect(filled.subjectSafe)
        #expect(filled.scaleTo > 1)

        // A subject touching the top edge: the push-in is reduced or removed, never unsafe.
        let edge = UnitRect(x: 0.3, y: 0.0, width: 0.4, height: 0.5)
        let gentle = FramingPlanner.plan(pictureAspect: 9.0 / 16.0, canvasAspect: 9.0 / 16.0, subject: edge, focus: nil, requestedFit: .contain)
        #expect(gentle.subjectSafe)
        #expect(gentle.scaleTo < 1.06)

        // Visible region maths: a 2:1 picture covering a 1:1 canvas shows the middle half.
        let visible = FramingPlanner.visibleRect(pictureAspect: 2, canvasAspect: 1, fit: .cover, scale: 1, center: .center)
        #expect(abs(visible.width - 0.5) < 1e-9 && abs(visible.x - 0.25) < 1e-9 && abs(visible.height - 1) < 1e-9)
        // Focus is clamped so no empty canvas shows.
        let left = FramingPlanner.visibleRect(pictureAspect: 2, canvasAspect: 1, fit: .cover, scale: 1, center: UnitPoint2D(x: 0, y: 0.5))
        #expect(abs(left.x) < 1e-9)
    }

    @Test func stripReelGivesEveryPanelItsTimeThenRevealsTheStrip() throws {
        let (engine, strip, _) = try Self.comic()
        let sequence = try ComicBuilder.stripReel(project: engine.project, stripID: strip.id, sequenceID: UUID(), name: "Strip reel")
        let main = try #require(sequence.mainTrack)
        #expect(main.clips.count == 4)
        #expect(main.clips.map(\.name) == ["Panel 1", "Panel 2", "Panel 3", "Full strip"])
        // Cuts are 3.6 s apart; the last panel runs long to cover the dissolve into the full strip.
        #expect(main.clips.map(\.start) == [seconds(0), seconds(3.6), seconds(7.2), seconds(10.8)])
        #expect(main.clips[0].transform.crop == strip.panels[0].rect)
        #expect(main.clips[0].transform.backdrop == .color)
        #expect(main.clips[3].transform.crop == .full)
        #expect(sequence.duration == seconds(14))
        #expect(main.clips[0].hasKeyframes(for: .scale), "gentle push-in")

        var copy = engine
        try copy.execute(.addSequence(sequence: sequence, activate: true))
        #expect(ProjectValidator.validate(copy.project).isEmpty)

        // Varied transitions and the end card.
        try copy.execute(.comic(command: .setEndCard(endCard: EndCard(enabled: true, text: "@mycomics"))))
        let varied = try ComicBuilder.stripReel(project: copy.project, stripID: strip.id,
                                                options: StripReelOptions(varyTransitions: true), sequenceID: UUID(), name: "Varied")
        let clips = try #require(varied.mainTrack).clips
        #expect(clips.last?.kind == .solid)
        #expect(clips.compactMap { $0.transitionIn?.type } == [.dissolve, .pageFold, .dissolve, .dissolve])
        #expect(clips[1].start == seconds(3.6), "cut points stay on the grid even with overlapping transitions")
        #expect(varied.tracks.contains { $0.kind == .text && $0.clips.first?.start == clips.last?.start })
        try copy.execute(.addSequence(sequence: varied, activate: false))
        #expect(ProjectValidator.validate(copy.project).isEmpty)
    }

    @Test func montageFollowsTheTimesGrid() throws {
        var engine = CommandEngine(project: Fixture.reel())
        let frames = (1...4).map { Fixture.image("frame\($0).png") }
        let song = Fixture.audio("owned.m4a", duration: 12)
        try engine.execute(.importAssets(assets: frames + [song]))
        try engine.execute(.comic(command: .enable(number: 1, slug: "golden hour")))
        let json = Data("[{\"line\":\"frame1\",\"start\":0,\"end\":2.4},{\"line\":\"frame2\",\"start\":2.4,\"end\":4.8},{\"line\":\"FRAME3.png\",\"start\":4.8,\"end\":6},{\"line\":\"frame4\",\"start\":6,\"end\":9.5}]".utf8)
        var plan = MontagePlan(frames: try ComicBuilder.montageFrames(fromTimesJSON: json, assets: engine.project.assets), audioAssetID: song.id)
        plan.frames[1].section = .verse
        plan.frames[1].transition = ComicBuilder.defaultTransition(for: .verse, rate: .fps30)
        plan.frames[2].section = .chorus
        plan.frames[3].section = .final
        plan.frames[3].transition = ComicBuilder.defaultTransition(for: .final, rate: .fps30)
        try engine.execute(.comic(command: .setMontage(plan: plan)))
        let sequence = try ComicBuilder.montage(project: engine.project, sequenceID: UUID(), name: "Montage")
        let clips = try #require(sequence.mainTrack).clips
        #expect(clips.map(\.start) == [seconds(0), seconds(2.4), seconds(4.8), seconds(6)])
        #expect(clips[2].transitionIn == nil, "chorus frames cut hard")
        #expect(clips[1].transitionIn?.type == .dissolve)
        #expect(sequence.duration == seconds(9.5))
        #expect(sequence.tracks.contains { $0.kind == .audio && $0.clips.first?.duration == seconds(9.5) })
        try engine.execute(.addSequence(sequence: sequence, activate: true))
        #expect(ProjectValidator.validate(engine.project).isEmpty)

        #expect(throws: EditError.self) { try ComicBuilder.montageFrames(fromTimesJSON: Data("[{\"line\":\"nope\",\"start\":0,\"end\":1}]".utf8), assets: frames) }
        #expect(throws: EditError.self) { try ComicBuilder.montageFrames(fromTimesJSON: Data("{}".utf8), assets: frames) }
    }

    @Test func lyricEditPlacesPicturesAndLetteringOnSongTime() throws {
        var engine = CommandEngine(project: Fixture.reel())
        let art = (1...2).map { Fixture.image("line\($0).png") }
        let song = Fixture.audio("owned.m4a", duration: 10)
        try engine.execute(.importAssets(assets: art + [song]))
        try engine.execute(.comic(command: .enable(number: 2, slug: "lyric")))
        let lines = [
            LyricLine(start: seconds(1), end: seconds(4), text: "you are my *sunshine*", style: .verse,
                      shots: [LyricShot(at: seconds(1), assetID: art[0].id)]),
            LyricLine(start: seconds(4), end: seconds(8), text: "MY ONLY / *SUNSHINE*", style: .chorus,
                      shots: [LyricShot(at: seconds(4), assetID: art[1].id, cut: .flash),
                              LyricShot(at: seconds(6), assetID: art[1].id, zoom: 1.6, focus: UnitPoint2D(x: 0.5, y: 0.7), cut: .shake)]),
        ]
        try engine.execute(.comic(command: .setLyricEdit(edit: LyricEdit(audioAssetID: song.id, lines: lines))))
        let sequence = try ComicBuilder.lyricEdit(project: engine.project, sequenceID: UUID(), name: "Lyric edit")
        let pictures = try #require(sequence.mainTrack).clips
        #expect(pictures.count == 3)
        #expect(pictures[0].start == .zero, "the first picture holds from the very start")
        #expect(pictures[1].start == seconds(4))
        #expect(pictures[1].transitionIn?.type == .dipToWhite)
        #expect(pictures[2].start == seconds(6))
        #expect(pictures[2].transform.scale == 1.6)
        #expect(sequence.duration == seconds(10), "runs to the end of the song")

        let lettering = try #require(sequence.tracks.first { $0.name == "Lyrics" }).clips
        #expect(lettering.count == 2)
        #expect(lettering[0].start == seconds(1))
        let presentation = try #require(lettering[0].text?.lyric)
        #expect(presentation.wordTimes.count == 4)
        #expect(presentation.wordTimes.first == .zero)
        #expect(lettering[1].text?.lyric?.flashOnHit == true)
        #expect(lettering[1].text?.style.allCaps == true)
        try engine.execute(.addSequence(sequence: sequence, activate: true))
        #expect(ProjectValidator.validate(engine.project).isEmpty)
    }
}
