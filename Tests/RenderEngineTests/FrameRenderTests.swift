import CoreGraphics
import Foundation
import MediaServices
import ProjectDomain
import Testing
@testable import RenderEngine

@Suite("Frame rendering")
struct FrameRenderTests {
    @Test func solidsAndCanvasBackground() async throws {
        var project = engine(background: RGBAColor(r: 0.2, g: 0.2, b: 0.2))
        try add(&project, solid(red, duration: 2))
        let frame = try await render(project, at: 1)
        #expect(frame.pixel(0.5, 0.5).isClose(to: (0.9, 0.1, 0.1)))
        #expect(frame.width == 270 && frame.height == 480)
    }

    @Test func stillsFitCropAndPosition() async throws {
        let root = try renderScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // A wide green picture on a tall canvas.
        let url = root.appendingPathComponent("wide.png")
        try SampleMedia.writeStill(to: url, width: 800, height: 400, color: green, label: "")
        var project = engine(background: RGBAColor(r: 0, g: 0, b: 0))
        let asset = try await importAsset(url)
        try project.execute(.importAssets(assets: [asset]))
        let clip = UUID()
        try project.execute(.addClip(sequenceID: nil, clipID: clip, assetID: asset.id, trackID: nil, start: nil, sourceStart: nil, duration: t(2), index: nil))

        // Contain: letterboxed — picture in the middle, background above and below.
        var frame = try await render(project, at: 1)
        #expect(frame.pixel(0.1, 0.5).isClose(to: (0.1, 0.8, 0.2)))
        #expect(frame.pixel(0.5, 0.1).isClose(to: (0, 0, 0)))
        #expect(frame.pixel(0.5, 0.9).isClose(to: (0, 0, 0)))

        // Cover: fills the canvas.
        try project.execute(.setTransform(clipID: clip, transform: ClipTransform(fit: .cover)))
        frame = try await render(project, at: 1)
        #expect(frame.pixel(0.5, 0.05).isClose(to: (0.1, 0.8, 0.2)))

        // Move the contained picture to the top third; the middle becomes background.
        try project.execute(.setTransform(clipID: clip, transform: ClipTransform(position: UnitPoint2D(x: 0.5, y: 0.15), fit: .contain)))
        frame = try await render(project, at: 1)
        #expect(frame.pixel(0.1, 0.15).isClose(to: (0.1, 0.8, 0.2)))
        #expect(frame.pixel(0.5, 0.6).isClose(to: (0, 0, 0)))

        // A paper-coloured backdrop fills the letterbox instead of the canvas colour.
        try project.execute(.setTransform(clipID: clip, transform: ClipTransform(fit: .contain, backdrop: .color, backdropColor: .paper)))
        frame = try await render(project, at: 1)
        #expect(frame.pixel(0.5, 0.05).isClose(to: (0.957, 0.925, 0.859), tolerance: 0.04))

        // Opacity keyframes fade the layer.
        try project.execute(.setTransform(clipID: clip, transform: ClipTransform(fit: .cover)))
        try project.execute(.setKeyframe(clipID: clip, keyframe: Keyframe(property: .opacity, time: .zero, value: 0, easing: .linear)))
        try project.execute(.setKeyframe(clipID: clip, keyframe: Keyframe(property: .opacity, time: t(2), value: 1, easing: .linear)))
        let dim = try await render(project, at: 0.5).pixel(0.5, 0.05)
        let bright = try await render(project, at: 1.8).pixel(0.5, 0.05)
        #expect(dim.g < bright.g - 0.3)
    }

    @Test func cropShowsOnlyThePanel() async throws {
        let root = try renderScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("strip.png")
        let panels = try SampleMedia.writeComicStrip(to: url)
        var project = engine(background: .black)
        let asset = try await importAsset(url)
        try project.execute(.importAssets(assets: [asset]))
        // Panel 2 is the pink one in the middle-left of the strip.
        var clip = Clip(kind: .image, assetID: asset.id, name: "Panel 2", duration: t(2))
        clip.transform = ClipTransform(crop: panels[1], fit: .contain, backdrop: .color, backdropColor: .paper)
        try add(&project, clip)
        let frame = try await render(project, at: 1)
        // Inside the panel: its tint. Outside (letterbox): paper. Nowhere: panel 1's blue.
        #expect(frame.pixel(0.2, 0.5).isClose(to: (0.96, 0.80, 0.74), tolerance: 0.06))
        #expect(frame.pixel(0.5, 0.04).isClose(to: (0.957, 0.925, 0.859), tolerance: 0.04))
        #expect(frame.coverage(in: CGRect(x: 0, y: 0, width: 1, height: 1), differingFrom: (0.72, 0.83, 0.93), threshold: 0.05) > 0.99)
    }

    @Test func dissolveBlendsNeighbours() async throws {
        var project = engine()
        try add(&project, solid(red, duration: 2))
        try add(&project, solid(blue, duration: 2, transition: Transition(type: .dissolve, duration: t(1))))
        // Overlap is 1.0–2.0 s.
        #expect(try await render(project, at: 0.5).pixel(0.5, 0.5).isClose(to: (0.9, 0.1, 0.1)))
        let middle = try await render(project, at: 1.5).pixel(0.5, 0.5)
        #expect(middle.r > 0.3 && middle.r < 0.8 && middle.b > 0.3 && middle.b < 0.8, "halfway is a mix: \(middle)")
        #expect(try await render(project, at: 2.5).pixel(0.5, 0.5).isClose(to: (0.1, 0.2, 0.9)))
    }

    @Test(arguments: TransitionType.allCases)
    func everyTransitionStartsOnAAndEndsOnB(type: TransitionType) async throws {
        var project = engine()
        try add(&project, solid(red, duration: 2))
        try add(&project, solid(blue, duration: 2, transition: Transition(type: type, duration: t(1), direction: .left)))
        let model = try await model(project, size: CGSize(width: 180, height: 320))
        func mostly(_ seconds: Double, _ color: (Double, Double, Double)) -> Double {
            let image = FrameRenderer.renderImage(model: model, at: t(seconds))!
            return 1 - Bitmap(image)!.coverage(in: CGRect(x: 0, y: 0, width: 1, height: 1), differingFrom: color, threshold: 0.2)
        }
        #expect(mostly(1.0, (0.9, 0.1, 0.1)) > 0.9, "\(type) must begin on the outgoing clip")
        #expect(mostly(1.99, (0.1, 0.2, 0.9)) > 0.85, "\(type) must end on the incoming clip")
        #expect(mostly(2.1, (0.1, 0.2, 0.9)) > 0.99, "after \(type) only the incoming clip shows")
        // Somewhere in the middle both pictures are involved.
        let midA = mostly(1.5, (0.9, 0.1, 0.1)), midB = mostly(1.5, (0.1, 0.2, 0.9))
        #expect(midA < 0.98 && midB < 0.98, "\(type) midpoint should not be a plain cut: a=\(midA) b=\(midB)")
    }

    @Test func reduceMotionSwapsMotionForDissolves() async throws {
        var project = engine()
        try add(&project, solid(red, duration: 2))
        try add(&project, solid(blue, duration: 2, transition: Transition(type: .push, duration: t(1), direction: .left)))
        let moving = try await model(project, size: CGSize(width: 180, height: 320))
        let calm = try await model(project, size: CGSize(width: 180, height: 320), options: RenderOptions(reduceMotion: true))
        // Push: left side still red, right side already blue. Dissolve: a uniform blend.
        let pushed = Bitmap(FrameRenderer.renderImage(model: moving, at: t(1.5))!)!
        #expect(pushed.pixel(0.1, 0.5).r > 0.7 && pushed.pixel(0.9, 0.5).b > 0.7)
        let blended = Bitmap(FrameRenderer.renderImage(model: calm, at: t(1.5))!)!
        #expect(abs(blended.pixel(0.1, 0.5).r - blended.pixel(0.9, 0.5).r) < 0.05)
    }

    @Test func overlaysBlendAndStack() async throws {
        var project = engine()
        try add(&project, solid(RGBAColor(r: 0.5, g: 0.5, b: 0.5), duration: 2))
        let overlay = UUID()
        try project.execute(.addTrack(sequenceID: nil, trackID: overlay, kind: .overlay, name: nil, index: nil))
        var top = solid(RGBAColor(r: 1, g: 0, b: 0), duration: 2)
        top.transform.opacity = 0.5
        try add(&project, top, track: overlay)
        let normal = try await render(project, at: 1).pixel(0.5, 0.5)
        #expect(normal.r > 0.65 && normal.g < 0.4, "50% red over grey: \(normal)")

        let clip = try #require(project.project.activeSequence.track(overlay)?.clips.first)
        try project.execute(.setTransform(clipID: clip.id, transform: ClipTransform()))
        try project.execute(.setLook(clipID: clip.id, color: .neutral, filters: [], blendMode: .multiply, mask: nil, chromaKey: nil))
        let multiplied = try await render(project, at: 1).pixel(0.5, 0.5)
        #expect(multiplied.g < 0.05 && multiplied.r > 0.15 && multiplied.r < 0.6, "red × grey: \(multiplied)")

        // Hidden tracks are not rendered.
        try project.execute(.setTrackState(trackID: overlay, muted: nil, hidden: true, locked: nil, gain: nil, name: nil))
        #expect(try await render(project, at: 1).pixel(0.5, 0.5).isClose(to: (0.5, 0.5, 0.5)))
    }

    @Test func colourAndLooks() async throws {
        let grey = RGBAColor(r: 0.5, g: 0.5, b: 0.5)
        func rendered(_ color: ColorAdjust = .neutral, _ filters: [AppliedFilter] = []) async throws -> Pixel {
            let root = try renderScratch("look\(UUID().uuidString.prefix(4))")
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("card.png")
            try SampleMedia.writeStill(to: url, width: 200, height: 200, color: RGBAColor(r: 0.8, g: 0.5, b: 0.3), label: "")
            var project = engine(width: 400, height: 400, background: grey)
            let asset = try await importAsset(url)
            try project.execute(.importAssets(assets: [asset]))
            let id = UUID()
            try project.execute(.addClip(sequenceID: nil, clipID: id, assetID: asset.id, trackID: nil, start: nil, sourceStart: nil, duration: t(1), index: nil))
            try project.execute(.setLook(clipID: id, color: color, filters: filters, blendMode: .normal, mask: nil, chromaKey: nil))
            return try await render(project, at: 0.5, size: CGSize(width: 200, height: 200)).pixel(0.1, 0.1)
        }
        let plain = try await rendered()
        #expect(plain.isClose(to: (0.8, 0.5, 0.3), tolerance: 0.05))
        let brighter = try await rendered(ColorAdjust(exposure: 1))
        #expect(brighter.r > plain.r + 0.08 || brighter.g > plain.g + 0.1)
        let warm = try await rendered(ColorAdjust(temperature: 0.8))
        let cool = try await rendered(ColorAdjust(temperature: -0.8))
        #expect(warm.r - warm.b > cool.r - cool.b + 0.1, "warm \(warm) vs cool \(cool)")
        let desaturated = try await rendered(ColorAdjust(saturation: -1))
        #expect(abs(desaturated.r - desaturated.b) < 0.06, "fully desaturated is grey: \(desaturated)")
        let mono = try await rendered(.neutral, [AppliedFilter(kind: .mono)])
        #expect(abs(mono.r - mono.b) < 0.06)
        let halfMono = try await rendered(.neutral, [AppliedFilter(kind: .mono, intensity: 0.5)])
        #expect(abs(halfMono.r - halfMono.b) > 0.1 && abs(halfMono.r - halfMono.b) < abs(plain.r - plain.b) - 0.05, "intensity mixes: \(halfMono)")
        let disabled = try await rendered(.neutral, [AppliedFilter(kind: .mono, enabled: false)])
        #expect(disabled.isClose(to: (plain.r, plain.g, plain.b), tolerance: 0.02))
        // Every filter renders something finite and opaque.
        for kind in FilterKind.allCases {
            let pixel = try await rendered(.neutral, [AppliedFilter(kind: kind, intensity: 0.8)])
            #expect(pixel.a > 0.95, "\(kind) kept the picture opaque")
        }
    }

    @Test func chromaKeyAndMasks() async throws {
        let root = try renderScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("screen.png")
        try SampleMedia.writeStill(to: url, width: 400, height: 400, color: RGBAColor(r: 0, g: 1, b: 0), label: "")
        var project = engine(width: 400, height: 400)
        let asset = try await importAsset(url)
        try project.execute(.importAssets(assets: [asset]))
        try add(&project, solid(blue, duration: 2))
        let overlay = UUID()
        try project.execute(.addTrack(sequenceID: nil, trackID: overlay, kind: .overlay, name: nil, index: nil))
        let id = UUID()
        try project.execute(.addClip(sequenceID: nil, clipID: id, assetID: asset.id, trackID: overlay, start: .zero, sourceStart: nil, duration: t(2), index: nil))
        let size = CGSize(width: 200, height: 200)
        #expect(try await render(project, at: 1, size: size).pixel(0.1, 0.1).isClose(to: (0, 1, 0), tolerance: 0.12))

        // Keying out green reveals the blue beneath, but keeps the dark figure.
        try project.execute(.setLook(clipID: id, color: .neutral, filters: [], blendMode: .normal, mask: nil, chromaKey: ChromaKey()))
        var frame = try await render(project, at: 1, size: size)
        #expect(frame.pixel(0.1, 0.1).isClose(to: (0.1, 0.2, 0.9), tolerance: 0.12))
        #expect(frame.pixel(0.5, 0.56).isClose(to: (0.2, 0.2, 0.25), tolerance: 0.12), "the figure is not keyed")

        // An ellipse mask keeps the centre and drops the corners.
        try project.execute(.setLook(clipID: id, color: .neutral, filters: [], blendMode: .normal,
                                     mask: ClipMask(shape: .ellipse, rect: UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), feather: 0.1), chromaKey: nil))
        frame = try await render(project, at: 1, size: size)
        #expect(frame.pixel(0.05, 0.05).isClose(to: (0.1, 0.2, 0.9), tolerance: 0.12))
        #expect(frame.pixel(0.5, 0.3).isClose(to: (0, 1, 0), tolerance: 0.15))
    }
}

@Suite("Text rendering")
struct TextRenderTests {
    static func textClip(_ string: String, animation: TextAnimation = .none, duration: Double = 3, words: [TimedWord] = []) -> Clip {
        var style = TextStyle(fontName: "Helvetica Neue Bold", fontSize: 110, color: .white, strokeWidth: 0, shadow: nil)
        style.highlightColor = RGBAColor(r: 1, g: 0.9, b: 0)
        return Clip(kind: .text, name: string, duration: t(duration),
                    text: TextContent(string: string, role: .caption, style: style, animation: animation, words: words))
    }

    static func coverage(_ project: CommandEngine, at seconds: Double, in region: CGRect = CGRect(x: 0, y: 0.3, width: 1, height: 0.4)) async throws -> Double {
        try await render(project, at: seconds).coverage(in: region, differingFrom: (0, 0, 0))
    }

    @Test func titlesDrawAtTheirPosition() async throws {
        var project = engine()
        try add(&project, solid(.black, duration: 3))
        var clip = Self.textClip("KIRIE")
        clip.transform.position = UnitPoint2D(x: 0.5, y: 0.2)
        try add(&project, clip)
        let frame = try await render(project, at: 1)
        #expect(frame.coverage(in: CGRect(x: 0, y: 0.12, width: 1, height: 0.16), differingFrom: (0, 0, 0)) > 0.05)
        #expect(frame.coverage(in: CGRect(x: 0, y: 0.6, width: 1, height: 0.3), differingFrom: (0, 0, 0)) == 0)
    }

    @Test func typewriterRevealsCharactersOverTime() async throws {
        var project = engine()
        try add(&project, solid(.black, duration: 3))
        try add(&project, Self.textClip("TYPE ON TEXT", animation: .typewriter))
        let early = try await Self.coverage(project, at: 0.05)
        let middle = try await Self.coverage(project, at: 0.3)
        let done = try await Self.coverage(project, at: 2)
        #expect(early < middle && middle < done, "\(early) < \(middle) < \(done)")
    }

    @Test func karaokeHighlightsTheWordBeingSung() async throws {
        var project = engine()
        try add(&project, solid(.black, duration: 3))
        let words = [TimedWord(text: "ONE", start: .zero, end: t(1)), TimedWord(text: "TWO", start: t(1), end: t(2))]
        try add(&project, Self.textClip("ONE TWO", animation: .karaoke, words: words))
        func yellow(_ seconds: Double, left: Bool) async throws -> Double {
            let frame = try await render(project, at: seconds)
            let region = CGRect(x: left ? 0 : 0.5, y: 0.4, width: 0.5, height: 0.2)
            return 1 - frame.coverage(in: region, differingFrom: (1, 0.9, 0), threshold: 0.25)
        }
        #expect(try await yellow(0.5, left: true) > 0.03, "first word lit while it is sung")
        #expect(try await yellow(0.5, left: false) < 0.005)
        #expect(try await yellow(1.5, left: false) > 0.03, "then the second")
        #expect(try await yellow(1.5, left: true) < 0.005)
        #expect(try await yellow(2.5, left: true) < 0.005, "after the last word nothing is lit")
    }

    @Test func lyricWordsArriveOneByOne() async throws {
        var project = engine(background: .paper)
        try add(&project, solid(.paper, duration: 4))
        let presentation = LyricPresentation(style: .verse, wordTimes: [t(0), t(1), t(2)], verticalPosition: 0.2)
        let clip = Clip(kind: .text, name: "lyric", duration: t(4),
                        text: TextContent(string: "you are / *sunshine*", role: .lyric, style: ComicBuilder.lyricTextStyle(for: .verse), lyric: presentation))
        try add(&project, clip)
        let region = CGRect(x: 0, y: 0.05, width: 1, height: 0.3)
        func ink(_ seconds: Double) async throws -> Double {
            try await render(project, at: seconds).coverage(in: region, differingFrom: (0.957, 0.925, 0.859), threshold: 0.2)
        }
        let one = try await ink(0.5), two = try await ink(1.5), three = try await ink(2.6)
        #expect(one > 0.002, "the first word is visible")
        #expect(two > one * 1.4, "a second word appears: \(one) → \(two)")
        #expect(three > two * 1.3, "then the emphasised word: \(two) → \(three)")
        // Lettering stays in the top area and never touches the lower picture area.
        #expect(try await render(project, at: 3).coverage(in: CGRect(x: 0, y: 0.45, width: 1, height: 0.55), differingFrom: (0.957, 0.925, 0.859)) == 0)
        // The line fades out at its end.
        #expect(try await ink(3.99) < three * 0.5)
    }

    @Test(arguments: LyricStyle.allCases)
    func everyLyricStyleFitsTheFrame(style: LyricStyle) async throws {
        var project = engine(background: .black)
        try add(&project, solid(.black, duration: 4))
        let text = "this is a deliberately long lyric line / that must *never* run off the side of the frame"
        let count = LyricMarkup.parse(text).wordCount
        let presentation = LyricPresentation(style: style, wordTimes: Array(repeating: .zero, count: count), verticalPosition: 0.25)
        try add(&project, Clip(kind: .text, name: "long", duration: t(4),
                               text: TextContent(string: text, role: .lyric, style: ComicBuilder.lyricTextStyle(for: style), lyric: presentation)))
        let frame = try await render(project, at: 2)
        #expect(frame.coverage(in: CGRect(x: 0.05, y: 0, width: 0.9, height: 0.6), differingFrom: (0, 0, 0)) > 0.01, "\(style) draws lettering")
        // Auto shrink-to-fit: nothing in the outer 2% columns.
        #expect(frame.coverage(in: CGRect(x: 0, y: 0, width: 0.02, height: 1), differingFrom: (0, 0, 0)) == 0, "\(style) overflows left")
        #expect(frame.coverage(in: CGRect(x: 0.98, y: 0, width: 0.02, height: 1), differingFrom: (0, 0, 0)) == 0, "\(style) overflows right")
    }
}
