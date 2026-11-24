import Foundation

public struct StripReelOptions: Hashable, Sendable, Codable {
    /// Solo screen time per panel.
    public var perPanel: RationalTime
    /// End scale of the gentle push-in on each panel.
    public var maxZoom: Double
    public var revealFullStrip: Bool
    public var fullStripDuration: RationalTime
    /// Transition between panels. Nil = hard cuts.
    public var transition: Transition?
    /// Use a different natural transition at every cut.
    public var varyTransitions: Bool
    /// Minimum clear space around the subject, as a fraction of the visible area.
    public var margin: Double

    public init(perPanel: RationalTime = RationalTime(seconds: 3.6), maxZoom: Double = 1.06, revealFullStrip: Bool = true,
                fullStripDuration: RationalTime = RationalTime(seconds: 3.2), transition: Transition? = nil,
                varyTransitions: Bool = false, margin: Double = 0.04) {
        self.perPanel = perPanel
        self.maxZoom = maxZoom
        self.revealFullStrip = revealFullStrip
        self.fullStripDuration = fullStripDuration
        self.transition = transition
        self.varyTransitions = varyTransitions
        self.margin = margin
    }
}

/// Builds ordinary timelines from Comic Studio data. The results are plain sequences: everything a
/// builder produces can be opened and edited like any hand-made timeline.
public enum ComicBuilder {
    static let variedCycle: [TransitionType] = [.dissolve, .pageFold, .slide, .polaroidDrop, .wipe, .zoom, .iris, .panelSlide]
    static let variedDirections: [Direction] = [.left, .left, .up, .down, .right, .left, .left, .right]

    private static func aspect(of asset: MediaAsset, crop: UnitRect = .full) -> Double {
        let w = Double(max(1, asset.metadata.displayWidth)) * crop.width
        let h = Double(max(1, asset.metadata.displayHeight)) * crop.height
        return h > 0 ? w / h : 1
    }

    private static func motionKeyframes(owner: UUID, plan: FramingPlan, duration: RationalTime) -> [Keyframe] {
        var frames: [Keyframe] = []
        func add(_ property: AnimatableProperty, _ from: Double, _ to: Double) {
            guard abs(from - to) > 1e-6 else { return }
            frames.append(Keyframe(id: UUID(deriving: owner, salt: "\(property.rawValue)-a"), property: property, time: .zero,
                                   value: from, easing: .linear))
            frames.append(Keyframe(id: UUID(deriving: owner, salt: "\(property.rawValue)-b"), property: property, time: duration,
                                   value: to, easing: .easeInOut))
        }
        add(.scale, plan.scaleFrom, plan.scaleTo)
        add(.positionX, plan.positionFrom.x, plan.positionTo.x)
        add(.positionY, plan.positionFrom.y, plan.positionTo.y)
        return frames
    }

    /// Appends the signature end card: a solid card on the main track plus its lettering.
    private static func appendEndCard(_ endCard: EndCard, to main: inout [Clip], text: inout [Clip], owner: UUID,
                                      rate: FrameRate) {
        guard endCard.enabled, !endCard.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let duration = RationalTime.max(rate.frameDuration, endCard.duration.rounded(toFrame: rate))
        let start = main.last?.end ?? .zero
        let card = Clip(id: UUID(deriving: owner, salt: "endcard"), kind: .solid, name: "End card", start: start,
                        duration: duration, transitionIn: main.isEmpty ? nil : Transition(type: .dissolve, duration: RationalTime(seconds: 0.3)),
                        solidColor: endCard.background)
        main.append(card)
        var style = TextStyle(fontName: endCard.fontName, fontSize: 84, color: endCard.textColor, strokeWidth: 0, shadow: nil)
        style.maxWidth = 0.8
        let label = Clip(id: UUID(deriving: owner, salt: "endcard-text"), kind: .text, name: endCard.text, start: start,
                         duration: duration, text: TextContent(string: endCard.text, role: .title, style: style, animation: .fade))
        text.append(label)
    }

    /// Lays clips end to end so each cut lands where intended even when transitions overlap.
    private static func layoutMain(_ clips: inout [Clip]) {
        var sequence = Sequence(tracks: [Track(kind: .main, clips: clips)])
        sequence.rippleMainTrack()
        clips = sequence.tracks[0].clips
    }

    // MARK: Strip reel

    /// Panel-by-panel reel: each panel full-screen with gentle motion, then the whole strip.
    public static func stripReel(project: Project, stripID: UUID, options: StripReelOptions = StripReelOptions(),
                                 sequenceID: UUID, name: String) throws -> Sequence {
        guard let comic = project.comic, let strip = comic.strip(stripID) else { throw EditError.stripNotFound(stripID) }
        guard let asset = project.asset(strip.assetID) else { throw EditError.assetNotFound(strip.assetID) }
        guard !strip.panels.isEmpty else { throw EditError.invalid("Detect or draw the panels before building the reel.") }
        let rate = project.canvas.frameRate
        let canvasAspect = project.canvas.aspectRatio
        let perPanel = RationalTime.max(rate.frameDuration, options.perPanel.rounded(toFrame: rate))

        func transition(at index: Int) -> Transition? {
            guard index > 0 else { return nil }
            if options.varyTransitions {
                let slot = (index - 1) % variedCycle.count
                return Transition(type: variedCycle[slot], duration: RationalTime(seconds: 0.45).rounded(toFrame: rate),
                                  direction: variedDirections[slot])
            }
            return options.transition.map {
                Transition(type: $0.type, duration: RationalTime.max(rate.frameDuration, $0.duration.rounded(toFrame: rate)), direction: $0.direction)
            }
        }

        var transitions: [Transition?] = strip.panels.indices.map { transition(at: $0) }
        if options.revealFullStrip {
            transitions.append(Transition(type: .dissolve, duration: RationalTime(seconds: 0.5).rounded(toFrame: rate)))
        }

        var main: [Clip] = []
        for (index, panel) in strip.panels.enumerated() {
            let id = UUID(deriving: sequenceID, salt: "panel-\(index)")
            let plan = FramingPlanner.plan(pictureAspect: aspect(of: asset, crop: panel.rect), canvasAspect: canvasAspect,
                                           subject: panel.subject, focus: panel.focus, requestedFit: panel.fit,
                                           maxZoom: options.maxZoom, margin: options.margin)
            // Run long enough to cover the next transition so every panel keeps its solo time.
            let overlap = index + 1 < transitions.count ? (transitions[index + 1]?.duration ?? .zero) : .zero
            let duration = perPanel + overlap
            var transform = ClipTransform(position: plan.positionFrom, scale: plan.scaleFrom, crop: panel.rect, fit: plan.fit,
                                          backdrop: .color, backdropColor: strip.paperColor)
            transform.opacity = 1
            let clip = Clip(id: id, kind: .image, assetID: asset.id, name: "Panel \(index + 1)", duration: duration,
                            transform: transform, keyframes: motionKeyframes(owner: id, plan: plan, duration: duration),
                            transitionIn: transitions[index])
            main.append(clip)
        }
        if options.revealFullStrip {
            let id = UUID(deriving: sequenceID, salt: "full-strip")
            let duration = RationalTime.max(rate.frameDuration, options.fullStripDuration.rounded(toFrame: rate))
            let transform = ClipTransform(fit: .contain, backdrop: .color, backdropColor: strip.paperColor)
            main.append(Clip(id: id, kind: .image, assetID: asset.id, name: "Full strip", duration: duration, transform: transform,
                             transitionIn: transitions[strip.panels.count]))
        }
        var text: [Clip] = []
        layoutMain(&main)
        appendEndCard(comic.endCard, to: &main, text: &text, owner: sequenceID, rate: rate)
        layoutMain(&main)
        if let card = main.last, card.kind == .solid, let index = text.indices.last { text[index].start = card.start }

        var tracks = [Track(id: UUID(deriving: sequenceID, salt: "main"), kind: .main, clips: main)]
        if !text.isEmpty { tracks.append(Track(id: UUID(deriving: sequenceID, salt: "text"), kind: .text, name: "Text", clips: text)) }
        return Sequence(id: sequenceID, name: name, tracks: tracks)
    }

    // MARK: Montage

    /// Default transition for a montage section: verses dissolve, choruses cut hard.
    public static func defaultTransition(for section: MontageSection, rate: FrameRate) -> Transition? {
        switch section {
        case .verse: Transition(type: .dissolve, duration: RationalTime(seconds: 0.45).rounded(toFrame: rate))
        case .chorus, .peak: nil
        case .final: Transition(type: .dissolve, duration: RationalTime(seconds: 0.6).rounded(toFrame: rate))
        }
    }

    /// Photo montage: stills on a times grid.
    public static func montage(project: Project, sequenceID: UUID, name: String) throws -> Sequence {
        guard let comic = project.comic else { throw EditError.invalid("Turn on Comic Studio for this project first.") }
        let plan = comic.montage
        guard !plan.frames.isEmpty else { throw EditError.invalid("Add at least one frame to the montage.") }
        let rate = project.canvas.frameRate
        let frames = plan.frames.sorted { $0.start < $1.start }
        let canvasAspect = project.canvas.aspectRatio
        var main: [Clip] = []
        for (index, frame) in frames.enumerated() {
            guard let asset = project.asset(frame.assetID) else { throw EditError.assetNotFound(frame.assetID) }
            let id = UUID(deriving: sequenceID, salt: "frame-\(index)")
            // A frame holds until the next frame's start, so the grid never has holes.
            let start = index == 0 ? RationalTime.zero : frame.start.rounded(toFrame: rate)
            let end = (index + 1 < frames.count ? frames[index + 1].start : frame.end).rounded(toFrame: rate)
            let overlap = index + 1 < frames.count ? (frames[index + 1].transition?.duration.rounded(toFrame: rate) ?? .zero) : .zero
            let duration = RationalTime.max(rate.frameDuration, end - start) + overlap
            let framing = FramingPlanner.plan(pictureAspect: aspect(of: asset), canvasAspect: canvasAspect, subject: nil, focus: nil,
                                              requestedFit: plan.fit, maxZoom: frame.section == .peak ? 1.08 : 1.04)
            let transform = ClipTransform(position: framing.positionFrom, scale: framing.scaleFrom, fit: framing.fit, backdrop: .blur)
            var transition = index == 0 ? nil : frame.transition
            if var t = transition {
                t.duration = RationalTime.max(rate.frameDuration, t.duration.rounded(toFrame: rate))
                transition = t
            }
            main.append(Clip(id: id, kind: asset.kind == .video ? .video : .image, assetID: asset.id, name: asset.name,
                             duration: duration, transform: transform,
                             keyframes: motionKeyframes(owner: id, plan: framing, duration: duration), transitionIn: transition))
        }
        var text: [Clip] = []
        layoutMain(&main)
        appendEndCard(comic.endCard, to: &main, text: &text, owner: sequenceID, rate: rate)
        layoutMain(&main)
        if let card = main.last, card.kind == .solid, let index = text.indices.last { text[index].start = card.start }

        var tracks = [Track(id: UUID(deriving: sequenceID, salt: "main"), kind: .main, clips: main)]
        if !text.isEmpty { tracks.append(Track(id: UUID(deriving: sequenceID, salt: "text"), kind: .text, name: "Text", clips: text)) }
        if let audioID = plan.audioAssetID, let audio = project.asset(audioID) {
            let total = main.last?.end ?? .zero
            let length = RationalTime.min(total, audio.metadata.duration).floored(toFrame: rate)
            if length.isPositive {
                var clip = Clip(id: UUID(deriving: sequenceID, salt: "song"), kind: .audio, assetID: audioID, name: audio.name, duration: length)
                clip.audio.fadeOut = RationalTime.min(RationalTime(seconds: 0.6).rounded(toFrame: rate), length)
                tracks.append(Track(id: UUID(deriving: sequenceID, salt: "audio"), kind: .audio, name: "Song", clips: [clip]))
            }
        }
        return Sequence(id: sequenceID, name: name, tracks: tracks)
    }

    /// Reads a `times.json` grid (`[{"line": "frame1", "start": 0, "end": 2.4}, …]`), matching each
    /// entry to an asset by name (with or without extension).
    public static func montageFrames(fromTimesJSON data: Data, assets: [MediaAsset]) throws -> [MontageFrame] {
        struct Entry: Decodable { var line: String; var start: Double; var end: Double }
        guard data.count <= 1_000_000 else { throw EditError.invalid("The times file is too large.") }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw EditError.invalid("The times file must be a list of {\"line\", \"start\", \"end\"} entries.")
        }
        var frames: [MontageFrame] = []
        for (index, entry) in entries.enumerated() {
            guard entry.start.isFinite, entry.end.isFinite, entry.end > entry.start, entry.start >= 0 else {
                throw EditError.invalid("Entry \(index + 1) (\(entry.line)) needs an end after its start.")
            }
            let wanted = entry.line.lowercased()
            guard let asset = assets.first(where: {
                $0.name.lowercased() == wanted || ($0.name as NSString).deletingPathExtension.lowercased() == wanted
            }) else {
                throw EditError.invalid("No imported picture is named “\(entry.line)”.")
            }
            frames.append(MontageFrame(id: UUID(deriving: asset.id, salt: "times-\(index)"), assetID: asset.id,
                                       start: RationalTime(seconds: entry.start), end: RationalTime(seconds: entry.end)))
        }
        return frames
    }

    // MARK: Lyric edit

    public static func lyricTextStyle(for style: LyricStyle) -> TextStyle {
        let ink = RGBAColor(r: 0.13, g: 0.1, b: 0.09)
        let paper = RGBAColor(r: 1, g: 0.98, b: 0.93)
        switch style {
        case .verse:
            return TextStyle(fontName: "Chalkboard SE Bold", fontSize: 78, color: ink, strokeColor: paper, strokeWidth: 10,
                             shadow: nil, alignment: .center, lineSpacing: 6, maxWidth: 0.84)
        case .stack:
            return TextStyle(fontName: "Marker Felt Wide", fontSize: 92, color: ink, strokeColor: paper, strokeWidth: 12,
                             shadow: nil, alignment: .left, lineSpacing: 2, maxWidth: 0.8)
        case .chorus:
            return TextStyle(fontName: "Arial Rounded MT Bold", fontSize: 118, color: RGBAColor(r: 1, g: 0.86, b: 0.2),
                             strokeColor: ink, strokeWidth: 16, shadow: nil, alignment: .center, lineSpacing: 0, allCaps: true,
                             maxWidth: 0.9, highlightColor: RGBAColor(r: 0.95, g: 0.26, b: 0.22))
        case .block:
            return TextStyle(fontName: "Arial Rounded MT Bold", fontSize: 76, color: .white, strokeColor: ink, strokeWidth: 14,
                             shadow: TextShadow(color: RGBAColor(r: 0, g: 0, b: 0, a: 0.45), blur: 18, offsetX: 0, offsetY: 0),
                             alignment: .left, lineSpacing: 0, allCaps: true, maxWidth: 0.82)
        }
    }

    /// Lyric edit: one full-screen picture per shot, lettering built word by word in the picture's empty area.
    public static func lyricEdit(project: Project, sequenceID: UUID, name: String) throws -> Sequence {
        guard let comic = project.comic else { throw EditError.invalid("Turn on Comic Studio for this project first.") }
        let edit = comic.lyricEdit
        let lines = edit.lines.sorted { $0.start < $1.start }
        guard !lines.isEmpty else { throw EditError.invalid("Add at least one lyric line.") }
        let rate = project.canvas.frameRate
        let canvasAspect = project.canvas.aspectRatio
        let song = project.asset(edit.audioAssetID)
        let lastLineEnd = lines.map(\.end).max() ?? .zero
        let total = RationalTime.max(lastLineEnd, song?.metadata.duration ?? .zero).rounded(toFrame: rate)

        // Pictures
        let shots = lines.flatMap(\.shots).sorted { $0.at < $1.at }
        guard !shots.isEmpty else { throw EditError.invalid("Give at least one lyric line a picture.") }
        func cutTransition(_ cut: ShotCut) -> Transition? {
            switch cut {
            case .hard, .shake: nil
            case .ghost: Transition(type: .dissolve, duration: RationalTime(seconds: 0.2).rounded(toFrame: rate))
            case .flash: Transition(type: .dipToWhite, duration: RationalTime(seconds: 0.2).rounded(toFrame: rate))
            case .whoosh: Transition(type: .whip, duration: RationalTime(seconds: 0.25).rounded(toFrame: rate), direction: .left)
            }
        }
        let transitions: [Transition?] = shots.enumerated().map { index, shot in index == 0 ? nil : cutTransition(shot.cut) }
        var main: [Clip] = []
        for (index, shot) in shots.enumerated() {
            guard let asset = project.asset(shot.assetID) else { throw EditError.assetNotFound(shot.assetID) }
            let id = UUID(deriving: sequenceID, salt: "shot-\(index)")
            let start = index == 0 ? RationalTime.zero : shot.at.rounded(toFrame: rate)
            let end = index + 1 < shots.count ? shots[index + 1].at.rounded(toFrame: rate) : total
            let overlap = index + 1 < shots.count ? (transitions[index + 1]?.duration ?? .zero) : .zero
            let duration = RationalTime.max(rate.frameDuration, end - start) + overlap
            let zoom = max(1, min(shot.zoom.isFinite ? shot.zoom : 1, 6))
            let pictureAspect = aspect(of: asset)
            let endZoom = edit.punchIn ? zoom * 1.04 : zoom
            let from = FramingPlanner.position(forFocus: shot.focus, pictureAspect: pictureAspect, canvasAspect: canvasAspect, fit: edit.fit, scale: zoom)
            let to = FramingPlanner.position(forFocus: shot.focus, pictureAspect: pictureAspect, canvasAspect: canvasAspect, fit: edit.fit, scale: endZoom)
            let transform = ClipTransform(position: from, scale: zoom, fit: edit.fit, backdrop: edit.fit == .contain ? .blur : .none)
            var keyframes: [Keyframe] = []
            if edit.punchIn {
                keyframes.append(Keyframe(id: UUID(deriving: id, salt: "s0"), property: .scale, time: .zero, value: zoom, easing: .linear))
                keyframes.append(Keyframe(id: UUID(deriving: id, salt: "s1"), property: .scale, time: duration, value: endZoom, easing: .easeOut))
                if from != to {
                    keyframes.append(Keyframe(id: UUID(deriving: id, salt: "x0"), property: .positionX, time: .zero, value: from.x, easing: .linear))
                    keyframes.append(Keyframe(id: UUID(deriving: id, salt: "x1"), property: .positionX, time: duration, value: to.x, easing: .easeOut))
                    keyframes.append(Keyframe(id: UUID(deriving: id, salt: "y0"), property: .positionY, time: .zero, value: from.y, easing: .linear))
                    keyframes.append(Keyframe(id: UUID(deriving: id, salt: "y1"), property: .positionY, time: duration, value: to.y, easing: .easeOut))
                }
            }
            if shot.cut == .shake, index > 0 {
                // A short, decaying side-to-side shake on the cut.
                let step = rate.frameDuration * 2
                let offsets = [0.014, -0.011, 0.008, -0.005, 0.002, 0]
                keyframes.removeAll { $0.property == .positionX }
                for (k, offset) in offsets.enumerated() where step * Int64(k) < duration {
                    keyframes.append(Keyframe(id: UUID(deriving: id, salt: "shake-\(k)"), property: .positionX,
                                              time: step * Int64(k), value: from.x + offset, easing: .linear))
                }
            }
            main.append(Clip(id: id, kind: asset.kind == .video ? .video : .image, assetID: asset.id, name: asset.name,
                             duration: duration, transform: transform, keyframes: keyframes, transitionIn: transitions[index]))
        }
        layoutMain(&main)

        // Lettering
        var lettering: [Clip] = []
        for (index, line) in lines.enumerated() {
            let start = line.start.rounded(toFrame: rate)
            var end = line.end.rounded(toFrame: rate)
            if index + 1 < lines.count { end = RationalTime.min(end, lines[index + 1].start.rounded(toFrame: rate)) }
            guard end - start >= rate.frameDuration else { continue }
            let rows = LyricMarkup.parse(line.text)
            guard rows.wordCount > 0 else { continue }
            let absolute = WordTiming.distribute(wordCount: rows.wordCount, start: start, end: end, hold: line.hold, overrides: line.wordTimes)
            var presentation = LyricPresentation(style: line.style, wordTimes: absolute.map { $0 - start })
            presentation.letterJitter = edit.letterJitter
            presentation.stripe = edit.stripe
            presentation.flashOnHit = edit.chorusFlash && line.style == .chorus
            presentation.verticalPosition = line.style == .block ? 0.2 : 0.17
            let content = TextContent(string: line.text, role: .lyric, style: lyricTextStyle(for: line.style), lyric: presentation)
            lettering.append(Clip(id: UUID(deriving: sequenceID, salt: "line-\(index)"), kind: .text, name: rows.plainText,
                                  start: start, duration: end - start, text: content))
        }

        var cardText: [Clip] = []
        appendEndCard(comic.endCard, to: &main, text: &cardText, owner: sequenceID, rate: rate)
        layoutMain(&main)
        if let card = main.last, card.kind == .solid, let index = cardText.indices.last { cardText[index].start = card.start }

        var tracks = [Track(id: UUID(deriving: sequenceID, salt: "main"), kind: .main, clips: main),
                      Track(id: UUID(deriving: sequenceID, salt: "lyrics"), kind: .text, name: "Lyrics", clips: lettering)]
        if !cardText.isEmpty {
            tracks.append(Track(id: UUID(deriving: sequenceID, salt: "text"), kind: .text, name: "Text", clips: cardText))
        }
        if let song {
            let length = RationalTime.min(total, song.metadata.duration).floored(toFrame: rate)
            if length.isPositive {
                let clip = Clip(id: UUID(deriving: sequenceID, salt: "song"), kind: .audio, assetID: song.id, name: song.name, duration: length)
                tracks.append(Track(id: UUID(deriving: sequenceID, salt: "audio"), kind: .audio, name: "Song", clips: [clip]))
            }
        }
        return Sequence(id: sequenceID, name: name, tracks: tracks)
    }
}
