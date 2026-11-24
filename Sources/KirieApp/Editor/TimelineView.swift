import AppKit
import MediaServices
import ProjectDomain
import SwiftUI

/// SwiftUI wrapper for the AppKit timeline.
struct TimelineView: NSViewRepresentable {
    let editor: EditorModel
    // Values read here so SwiftUI refreshes the timeline when they change.
    let sequence: ProjectDomain.Sequence
    let selection: Set<UUID>
    let playhead: RationalTime
    let zoom: Double
    let trackScale: Double
    let cacheGeneration: Int
    let isPlaying: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.usesPredominantAxisScrolling = true
        let timeline = TimelineNSView(editor: editor)
        scroll.documentView = timeline
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(timeline, selector: #selector(TimelineNSView.viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(timeline, selector: #selector(TimelineNSView.viewportChanged), name: NSView.frameDidChangeNotification, object: scroll)
        scroll.postsFrameChangedNotifications = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let timeline = scroll.documentView as? TimelineNSView else { return }
        timeline.update(sequence: sequence, selection: selection, playhead: playhead, zoom: zoom, trackScale: trackScale, isPlaying: isPlaying, cacheGeneration: cacheGeneration)
    }
}

/// The multitrack timeline, drawn and hit-tested by hand for precision and speed. Only what is
/// visible is drawn, so timelines with thousands of clips stay smooth.
final class TimelineNSView: NSView {
    static let headerWidth: CGFloat = 132
    static let rulerHeight: CGFloat = 26
    static let assetDragPrefix = "kirie-asset:"

    private let editor: EditorModel
    private var sequence = ProjectDomain.Sequence()
    private var selection: Set<UUID> = []
    private var playhead: RationalTime = .zero
    private var zoom: Double = 80
    private var trackScale: Double = 1
    private var isPlaying = false

    private struct Row {
        var track: Track
        var y: CGFloat
        var height: CGFloat
    }

    private var rows: [Row] = []

    private enum Drag {
        case none
        case scrub
        case pending(clipID: UUID, origin: CGPoint, grab: RationalTime)
        case move(clipID: UUID, grab: RationalTime, start: RationalTime, trackID: UUID, insertIndex: Int?)
        case trim(clipID: UUID, edge: TrimEdge, time: RationalTime)
    }

    private var drag: Drag = .none
    private var snapLine: RationalTime?
    private var headerButtons: [(rect: CGRect, action: () -> Void)] = []
    private var dropHighlight: (trackID: UUID?, time: RationalTime)?

    init(editor: EditorModel) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        registerForDraggedTypes([.string, .fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline")
        setAccessibilityHelp("Clips on tracks. Use the Storyboard list for a keyboard and VoiceOver friendly view of the main track.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: State

    private var cacheGeneration = -1

    func update(sequence: ProjectDomain.Sequence, selection: Set<UUID>, playhead: RationalTime, zoom: Double, trackScale: Double, isPlaying: Bool,
                cacheGeneration: Int) {
        let structural = sequence != self.sequence || zoom != self.zoom || trackScale != self.trackScale
        // Selection and newly arrived thumbnails need a full repaint; a moving playhead alone does not.
        let repaint = selection != self.selection || cacheGeneration != self.cacheGeneration
        self.cacheGeneration = cacheGeneration
        let oldPlayhead = self.playhead
        self.sequence = sequence
        self.selection = selection
        self.zoom = zoom
        self.trackScale = trackScale
        self.isPlaying = isPlaying
        self.playhead = playhead
        if structural {
            layoutRows()
            resizeToContent()
        }
        if !structural, !repaint, playhead != oldPlayhead {
            // Repaint only the two playhead columns.
            for time in [oldPlayhead, playhead] {
                setNeedsDisplay(CGRect(x: x(for: time) - 8, y: 0, width: 16, height: bounds.height))
            }
            if let visible = enclosingScrollView?.documentVisibleRect {
                setNeedsDisplay(CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: TimelineNSView.rulerHeight))
            }
            followPlayhead()
        } else {
            needsDisplay = true
        }
    }

    private func height(for kind: TrackKind) -> CGFloat {
        let base: CGFloat = switch kind {
        case .main: 62
        case .overlay: 50
        case .audio: 44
        case .text, .caption: 30
        }
        return (base * CGFloat(trackScale)).rounded()
    }

    /// Upper layers sit higher; audio tracks go underneath, as editors conventionally show them.
    private func layoutRows() {
        var y = TimelineNSView.rulerHeight
        var laid: [Row] = []
        let visual = sequence.tracks.enumerated().filter { $0.element.kind.isVisual }.reversed().map(\.element)
        let audio = sequence.tracks.filter { $0.kind == .audio }
        for track in visual + audio {
            let h = height(for: track.kind)
            laid.append(Row(track: track, y: y, height: h))
            y += h
        }
        rows = laid
    }

    private var contentHeight: CGFloat { (rows.last.map { $0.y + $0.height } ?? TimelineNSView.rulerHeight) + 28 }

    private func resizeToContent() {
        let visible = enclosingScrollView?.contentSize ?? CGSize(width: 800, height: 240)
        // Room after the last clip to drop new ones.
        let width = TimelineNSView.headerWidth + CGFloat(sequence.duration.seconds + 6) * CGFloat(zoom) + 200
        setFrameSize(NSSize(width: max(visible.width, width), height: max(visible.height, contentHeight)))
    }

    @objc func viewportChanged() {
        resizeToContent()
        needsDisplay = true
    }

    private func followPlayhead() {
        guard isPlaying, let scroll = enclosingScrollView else { return }
        let visible = scroll.documentVisibleRect
        let px = x(for: playhead)
        if px > visible.maxX - 40 || px < visible.minX + TimelineNSView.headerWidth {
            let target = max(0, px - TimelineNSView.headerWidth - 40)
            scroll.contentView.scroll(to: CGPoint(x: min(target, max(0, bounds.width - visible.width)), y: visible.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // MARK: Geometry

    private func x(for time: RationalTime) -> CGFloat { TimelineNSView.headerWidth + CGFloat(time.seconds * zoom) }

    private func time(at x: CGFloat) -> RationalTime {
        let seconds = max(0, Double(x - TimelineNSView.headerWidth) / zoom)
        return RationalTime(seconds: seconds).rounded(toFrame: editor.frameRate)
    }

    private func rect(for clip: Clip, in row: Row) -> CGRect {
        CGRect(x: x(for: clip.start), y: row.y + 3, width: max(2, CGFloat(clip.duration.seconds * zoom)), height: row.height - 6)
    }

    private func row(at y: CGFloat) -> Row? { rows.first { y >= $0.y && y < $0.y + $0.height } }

    private func hit(_ point: CGPoint) -> (clip: Clip, row: Row, rect: CGRect)? {
        guard let row = row(at: point.y) else { return nil }
        // Later clips on the main track draw over earlier ones during a transition.
        for clip in row.track.clips.reversed() {
            let r = rect(for: clip, in: row)
            if r.contains(point) { return (clip, row, r) }
        }
        return nil
    }

    private func snapped(_ time: RationalTime, excluding: Set<UUID>, disabled: Bool) -> RationalTime {
        guard editor.snapping, !disabled else { snapLine = nil; return time }
        let targets = Snapping.targets(in: sequence, playhead: playhead, excluding: excluding)
        let result = Snapping.snap(time, to: targets, tolerance: RationalTime(seconds: 8 / zoom))
        snapLine = result.target?.time
        return result.time.rounded(toFrame: editor.frameRate)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        Theme.NS.inset.setFill()
        dirtyRect.fill()

        // Lanes
        for (index, row) in rows.enumerated() {
            let lane = CGRect(x: visible.minX, y: row.y, width: visible.width, height: row.height)
            guard lane.intersects(dirtyRect) else { continue }
            (index % 2 == 0 ? Theme.NS.lane : Theme.NS.laneAlt).setFill()
            lane.fill()
            Theme.NS.grid.setFill()
            CGRect(x: visible.minX, y: row.y + row.height - 1, width: visible.width, height: 1).fill()
        }

        // Bar lines under the clips
        if zoom > 24 {
            Theme.NS.grid.setFill()
            for marker in sequence.markers where marker.kind == .downbeat {
                let px = x(for: marker.time)
                if px >= dirtyRect.minX - 1, px <= dirtyRect.maxX + 1 {
                    CGRect(x: px, y: TimelineNSView.rulerHeight, width: 1, height: contentHeight - TimelineNSView.rulerHeight - 28).fill()
                }
            }
        }

        // Clips (only those in view)
        for row in rows where row.y < dirtyRect.maxY && row.y + row.height > dirtyRect.minY {
            for clip in row.track.clips {
                let r = rect(for: clip, in: row)
                guard r.maxX >= dirtyRect.minX, r.minX <= dirtyRect.maxX else { continue }
                drawClip(clip, in: r, row: row, context: context, visible: visible)
            }
        }

        drawGhost(context)
        if let snapLine {
            Theme.NS.accent.setFill()
            CGRect(x: x(for: snapLine) - 0.5, y: TimelineNSView.rulerHeight, width: 1, height: bounds.height).fill()
        }
        drawRuler(visible: visible, dirty: dirtyRect)
        drawPlayhead(visible: visible)
        drawHeaders(visible: visible)
    }

    private func color(for clip: Clip) -> NSColor {
        switch clip.kind {
        case .video: Theme.NS.clipVideo
        case .image: Theme.NS.clipImage
        case .audio: Theme.NS.clipAudio
        case .text: Theme.NS.clipText
        case .solid: Theme.NS.clipSolid
        }
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    private func drawSymbol(_ name: String, at origin: CGPoint, size: CGFloat, color: NSColor) -> CGFloat {
        guard let image = symbol(name, size: size, color: color) else { return 0 }
        let target = CGRect(origin: origin, size: image.size)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return image.size.width
    }

    private func drawClip(_ clip: Clip, in r: CGRect, row: Row, context: CGContext, visible: CGRect) {
        let selected = selection.contains(clip.id)
        let asset = editor.project.asset(clip.assetID)
        let offline = asset.map { a in editor.missingMedia.contains { $0.id == a.id } } ?? false
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        context.saveGState()
        path.addClip()
        color(for: clip).setFill()
        r.fill()
        let drawStart = max(r.minX, visible.minX - 40), drawEnd = min(r.maxX, visible.maxX + 40)

        if offline {
            Theme.NS.warning.withAlphaComponent(0.25).setFill()
            r.fill()
        } else if clip.kind == .video || clip.kind == .image, r.height > 20, let asset {
            // Filmstrip: tiles the height of the clip, each showing the frame under it.
            let aspect = CGFloat(max(1, asset.metadata.displayWidth)) / CGFloat(max(1, asset.metadata.displayHeight))
            let tileHeight = r.height - 14, tileWidth = max(12, tileHeight * aspect)
            let strip = clip.kind == .video ? editor.cache.filmstrip(for: asset, session: editor.session) : nil
            let still = editor.cache.thumbnail(for: asset, session: editor.session)
            var tileX = r.minX + floor(max(0, drawStart - r.minX) / tileWidth) * tileWidth
            while tileX < drawEnd {
                let tile = CGRect(x: tileX, y: r.minY + 14, width: tileWidth, height: tileHeight)
                if let strip, !strip.isEmpty {
                    let local = Double(tile.midX - r.minX) / zoom
                    let source = clip.sourceStart.seconds + local * clip.speed
                    if let frame = strip.min(by: { abs($0.seconds - source) < abs($1.seconds - source) }) {
                        drawImage(frame.image, in: tile, context: context)
                    }
                } else if let still, let cg = still.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    drawImage(cg, in: tile, context: context)
                }
                tileX += tileWidth
            }
        } else if clip.kind == .audio, let asset, let waveform = editor.cache.waveform(for: asset, session: editor.session) {
            Theme.NS.waveform.setFill()
            let mid = r.midY + 5, half = (r.height - 16) / 2
            var px = floor(drawStart)
            while px < drawEnd {
                let local = Double(px - r.minX) / zoom, next = Double(px + 1 - r.minX) / zoom
                let a = clip.sourceStart.seconds + local * clip.speed, b = clip.sourceStart.seconds + next * clip.speed
                let peak = CGFloat(waveform.peak(from: a, to: b))
                let bar = max(1, peak * half * CGFloat(min(1.5, max(0.2, clip.audio.gain))))
                CGRect(x: px, y: mid - bar, width: 1, height: bar * 2).fill()
                px += 1
            }
        } else if clip.kind == .solid, let solid = clip.solidColor {
            NSColor(srgbRed: solid.r, green: solid.g, blue: solid.b, alpha: 1).setFill()
            CGRect(x: r.minX, y: r.minY + 14, width: r.width, height: r.height - 14).fill()
        }

        // Transition overlap: hatched wedge at the head of the incoming clip.
        if let transition = clip.transitionIn {
            let width = min(r.width, CGFloat(transition.duration.seconds * zoom))
            NSColor.black.withAlphaComponent(0.18).setFill()
            let wedge = NSBezierPath()
            wedge.move(to: CGPoint(x: r.minX, y: r.maxY))
            wedge.line(to: CGPoint(x: r.minX + width, y: r.minY))
            wedge.line(to: CGPoint(x: r.minX, y: r.minY))
            wedge.close()
            wedge.fill()
        }

        // Label strip
        var labelX = max(r.minX, visible.minX + TimelineNSView.headerWidth) + 5
        let labelColor = Theme.NS.text
        if r.width > 26 {
            if clip.transitionIn != nil { labelX += drawSymbol("arrow.left.arrow.right", at: CGPoint(x: labelX, y: r.minY + 2), size: 8, color: labelColor) + 3 }
            if offline { labelX += drawSymbol("exclamationmark.triangle.fill", at: CGPoint(x: labelX, y: r.minY + 2), size: 8, color: Theme.NS.warning) + 3 }
            if clip.audio.muted, clip.kind != .text, clip.kind != .image, clip.kind != .solid {
                labelX += drawSymbol("speaker.slash.fill", at: CGPoint(x: labelX, y: r.minY + 2), size: 8, color: labelColor) + 3
            }
            if !clip.filters.isEmpty || !clip.color.isNeutral { labelX += drawSymbol("wand.and.stars", at: CGPoint(x: labelX, y: r.minY + 2), size: 8, color: labelColor) + 3 }
            if !clip.keyframes.isEmpty { labelX += drawSymbol("diamond.fill", at: CGPoint(x: labelX, y: r.minY + 3), size: 6, color: labelColor) + 3 }
            var title = clip.kind == .text ? (clip.text.map { LyricMarkup.plainText($0.string) } ?? clip.name) : clip.name
            if clip.speed != 1 { title += String(format: "  %.2g×", clip.speed) }
            if offline { title += "  offline" }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: labelColor]
            let available = r.maxX - labelX - 4
            if available > 12 {
                NSAttributedString(string: title, attributes: attributes).draw(with: CGRect(x: labelX, y: r.minY + 1, width: available, height: 13),
                                                                               options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            }
        }
        context.restoreGState()

        if selected {
            Theme.NS.accent.setStroke()
            let outline = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            outline.lineWidth = 2
            outline.stroke()
            // Trim grips
            Theme.NS.accent.setFill()
            if r.width > 18 {
                CGRect(x: r.minX + 3, y: r.midY - 7, width: 2, height: 14).fill()
                CGRect(x: r.maxX - 5, y: r.midY - 7, width: 2, height: 14).fill()
            }
        }
    }

    private func drawGhost(_ context: CGContext) {
        switch drag {
        case .move(let clipID, _, let start, let trackID, let insertIndex):
            guard let clip = sequence.clip(clipID), let row = rows.first(where: { $0.track.id == trackID }) else { return }
            if let insertIndex {
                // Main track: show where the clip will be inserted.
                let clips = row.track.clips.filter { $0.id != clipID }
                let at = insertIndex < clips.count ? clips[insertIndex].start : (clips.last?.end ?? .zero)
                Theme.NS.accent.setFill()
                CGRect(x: x(for: at) - 1.5, y: row.y + 1, width: 3, height: row.height - 2).fill()
            } else {
                Theme.NS.ghost.setFill()
                NSBezierPath(roundedRect: CGRect(x: x(for: start), y: row.y + 3, width: CGFloat(clip.duration.seconds * zoom), height: row.height - 6), xRadius: 4, yRadius: 4).fill()
            }
        case .trim(let clipID, let edge, let time):
            guard let location = sequence.locate(clipID), let row = rows.first(where: { $0.track.id == sequence.tracks[location.track].id }) else { return }
            let clip = sequence.tracks[location.track].clips[location.clip]
            let from = edge == .start ? time : clip.start, to = edge == .start ? clip.end : time
            guard to > from else { return }
            Theme.NS.ghost.setFill()
            NSBezierPath(roundedRect: CGRect(x: x(for: from), y: row.y + 3, width: CGFloat((to - from).seconds * zoom), height: row.height - 6), xRadius: 4, yRadius: 4).fill()
            Theme.NS.accent.setFill()
            CGRect(x: x(for: time) - 1, y: row.y + 1, width: 2, height: row.height - 2).fill()
        default:
            break
        }
        if let dropHighlight {
            Theme.NS.accent.setFill()
            let row = rows.first { $0.track.id == dropHighlight.trackID }
            CGRect(x: x(for: dropHighlight.time) - 1, y: row?.y ?? TimelineNSView.rulerHeight, width: 2, height: row?.height ?? contentHeight).fill()
        }
    }

    private func drawRuler(visible: CGRect, dirty: CGRect) {
        let ruler = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: TimelineNSView.rulerHeight)
        Theme.NS.header.setFill()
        ruler.fill()
        Theme.NS.border.setFill()
        CGRect(x: ruler.minX, y: ruler.maxY - 1, width: ruler.width, height: 1).fill()

        // Pick a label interval that keeps labels readable at this zoom.
        let steps: [Double] = [1.0 / 30, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let major = steps.first { $0 * zoom >= 72 } ?? 600
        let minor = major / (major >= 1 ? 5 : 2)
        let startTime = max(0, Double(visible.minX) / zoom - major)
        let endTime = Double(visible.maxX - TimelineNSView.headerWidth) / zoom + major
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: Theme.NS.secondary]
        var tick = (startTime / minor).rounded(.down) * minor
        while tick <= endTime {
            let px = TimelineNSView.headerWidth + CGFloat(tick * zoom)
            let isMajor = abs(tick / major - (tick / major).rounded()) < 1e-6
            Theme.NS.tertiary.withAlphaComponent(isMajor ? 0.9 : 0.45).setFill()
            CGRect(x: px, y: ruler.maxY - (isMajor ? 9 : 5), width: 1, height: isMajor ? 8 : 4).fill()
            if isMajor {
                let label = major < 1 ? String(format: "%d:%05.2f", Int(tick) / 60, tick.truncatingRemainder(dividingBy: 60)) : formatDuration(tick)
                NSAttributedString(string: label, attributes: attributes).draw(at: CGPoint(x: px + 3, y: ruler.minY + 3))
            }
            tick += minor
        }
        // Markers. Shape tells the kinds apart, not just colour: beats are ticks, bar starts are
        // dots on a longer tick, ordinary markers are flags.
        for marker in sequence.markers {
            let px = x(for: marker.time)
            guard px >= visible.minX + TimelineNSView.headerWidth - 6, px <= visible.maxX + 6 else { continue }
            switch marker.kind {
            case .beat:
                Theme.NS.secondary.withAlphaComponent(0.7).setFill()
                CGRect(x: px - 0.5, y: ruler.maxY - 6, width: 1, height: 5).fill()
            case .downbeat:
                Theme.NS.warning.setFill()
                CGRect(x: px - 0.5, y: ruler.maxY - 10, width: 1.5, height: 9).fill()
                NSBezierPath(ovalIn: CGRect(x: px - 2.5, y: ruler.maxY - 14, width: 5, height: 5)).fill()
            case .standard, .section:
                NSColor(srgbRed: marker.color.r, green: marker.color.g, blue: marker.color.b, alpha: 1).setFill()
                let flag = NSBezierPath()
                flag.move(to: CGPoint(x: px, y: ruler.maxY - 1))
                flag.line(to: CGPoint(x: px, y: ruler.minY + 4))
                flag.line(to: CGPoint(x: px + 8, y: ruler.minY + 4))
                flag.line(to: CGPoint(x: px + 5, y: ruler.minY + 8))
                flag.line(to: CGPoint(x: px + 8, y: ruler.minY + 12))
                flag.line(to: CGPoint(x: px + 1.5, y: ruler.minY + 12))
                flag.line(to: CGPoint(x: px + 1.5, y: ruler.maxY - 1))
                flag.close()
                flag.fill()
            }
        }
    }

    private func drawPlayhead(visible: CGRect) {
        let px = x(for: playhead)
        guard px >= visible.minX + TimelineNSView.headerWidth - 8, px <= visible.maxX + 8 else { return }
        Theme.NS.playhead.setFill()
        CGRect(x: px - 0.5, y: visible.minY + TimelineNSView.rulerHeight - 4, width: 1.5, height: bounds.height).fill()
        let head = NSBezierPath()
        let top = visible.minY + 6
        head.move(to: CGPoint(x: px - 6, y: top))
        head.line(to: CGPoint(x: px + 6.5, y: top))
        head.line(to: CGPoint(x: px + 6.5, y: top + 9))
        head.line(to: CGPoint(x: px + 0.25, y: top + 16))
        head.line(to: CGPoint(x: px - 6, y: top + 9))
        head.close()
        head.fill()
    }

    private func drawHeaders(visible: CGRect) {
        headerButtons.removeAll()
        let column = CGRect(x: visible.minX, y: visible.minY, width: TimelineNSView.headerWidth, height: visible.height)
        Theme.NS.header.setFill()
        column.fill()
        Theme.NS.border.setFill()
        CGRect(x: column.maxX - 1, y: column.minY, width: 1, height: column.height).fill()
        for row in rows {
            let cell = CGRect(x: column.minX, y: row.y, width: column.width, height: row.height)
            // Rows scroll under the sticky ruler.
            guard cell.maxY > visible.minY + TimelineNSView.rulerHeight, cell.minY < visible.maxY else { continue }
            Theme.NS.border.setFill()
            CGRect(x: cell.minX, y: cell.maxY - 1, width: cell.width, height: 1).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                                                              .foregroundColor: row.track.locked ? Theme.NS.tertiary : Theme.NS.text]
            NSAttributedString(string: row.track.name, attributes: attributes)
                .draw(with: CGRect(x: cell.minX + 8, y: cell.midY - 7, width: 58, height: 14), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

            var buttonX = cell.maxX - 22
            let track = row.track
            func button(_ name: String, active: Bool, _ action: @escaping () -> Void) {
                let hit = CGRect(x: buttonX - 3, y: cell.midY - 10, width: 20, height: 20)
                _ = drawSymbol(name, at: CGPoint(x: buttonX, y: cell.midY - 6), size: 10, color: active ? Theme.NS.accent : Theme.NS.tertiary)
                headerButtons.append((hit, action))
                buttonX -= 21
            }
            button(track.locked ? "lock.fill" : "lock.open", active: track.locked) { [editor] in
                editor.perform(.setTrackState(trackID: track.id, muted: nil, hidden: nil, locked: !track.locked, gain: nil, name: nil), reload: false)
            }
            if track.kind == .audio || track.kind == .main || track.kind == .overlay {
                button(track.muted ? "speaker.slash.fill" : "speaker.wave.2", active: track.muted) { [editor] in
                    editor.perform(.setTrackState(trackID: track.id, muted: !track.muted, hidden: nil, locked: nil, gain: nil, name: nil))
                }
            }
            if track.kind.isVisual {
                button(track.hidden ? "eye.slash.fill" : "eye", active: track.hidden) { [editor] in
                    editor.perform(.setTrackState(trackID: track.id, muted: nil, hidden: !track.hidden, locked: nil, gain: nil, name: nil))
                }
            }
        }
        // Corner above the headers
        Theme.NS.header.setFill()
        let corner = CGRect(x: column.minX, y: visible.minY, width: column.width, height: TimelineNSView.rulerHeight)
        corner.fill()
        Theme.NS.border.setFill()
        CGRect(x: corner.minX, y: corner.maxY - 1, width: corner.width, height: 1).fill()
        CGRect(x: corner.maxX - 1, y: corner.minY, width: 1, height: corner.height).fill()
        let code = Timecode.string(playhead, rate: editor.frameRate)
        NSAttributedString(string: code, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: Theme.NS.secondary])
            .draw(at: CGPoint(x: corner.minX + 8, y: corner.minY + 6))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        if point.x < visible.minX + TimelineNSView.headerWidth {
            headerButtons.first { $0.rect.contains(point) }?.action()
            return
        }
        if point.y < visible.minY + TimelineNSView.rulerHeight {
            drag = .scrub
            editor.player.pause()
            editor.player.seek(to: time(at: point.x))
            return
        }
        if let (clip, row, rect) = hit(point) {
            let extend = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            if extend {
                if selection.contains(clip.id) { editor.selection.remove(clip.id) } else { editor.selection.insert(clip.id) }
            } else if !selection.contains(clip.id) {
                editor.selection = [clip.id]
            }
            guard !row.track.locked, !extend else { return }
            if event.clickCount == 2 {
                editor.player.seek(to: clip.start)
                return
            }
            let edgeZone = min(7, rect.width / 3)
            if point.x - rect.minX <= edgeZone {
                drag = .trim(clipID: clip.id, edge: .start, time: clip.start)
            } else if rect.maxX - point.x <= edgeZone {
                drag = .trim(clipID: clip.id, edge: .end, time: clip.end)
            } else {
                drag = .pending(clipID: clip.id, origin: point, grab: time(at: point.x) - clip.start)
            }
        } else {
            editor.selection = []
            drag = .scrub
            editor.player.pause()
            editor.player.seek(to: time(at: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let noSnap = event.modifierFlags.contains(.command)
        switch drag {
        case .none:
            return
        case .scrub:
            editor.player.seek(to: snapped(time(at: point.x), excluding: [], disabled: noSnap || !event.modifierFlags.contains(.shift)))
            snapLine = nil
        case .pending(let clipID, let origin, let grab):
            guard hypot(point.x - origin.x, point.y - origin.y) > 3, let location = sequence.locate(clipID) else { return }
            let clip = sequence.tracks[location.track].clips[location.clip]
            drag = .move(clipID: clipID, grab: grab, start: clip.start, trackID: sequence.tracks[location.track].id, insertIndex: nil)
            fallthrough
        case .move(let clipID, let grab, _, _, _):
            guard let location = sequence.locate(clipID) else { return }
            let clip = sequence.tracks[location.track].clips[location.clip]
            var start = RationalTime.max(.zero, time(at: point.x) - grab)
            // Snap whichever end is nearer a target.
            let head = snapped(start, excluding: [clipID], disabled: noSnap)
            if snapLine != nil {
                start = head
            } else {
                let tail = snapped(start + clip.duration, excluding: [clipID], disabled: noSnap)
                if snapLine != nil { start = RationalTime.max(.zero, tail - clip.duration) }
            }
            let origin = sequence.tracks[location.track]
            var target = origin
            if let hovered = row(at: point.y)?.track, hovered.kind.accepts(clip.kind), !hovered.locked { target = hovered }
            var insertIndex: Int?
            if target.kind.isMagnetic {
                let others = target.clips.filter { $0.id != clipID }
                let dropTime = time(at: point.x)
                insertIndex = others.firstIndex { ($0.start + $0.duration.scaled(by: 0.5)) > dropTime } ?? others.count
                snapLine = nil
            }
            drag = .move(clipID: clipID, grab: grab, start: start, trackID: target.id, insertIndex: insertIndex)
            needsDisplay = true
        case .trim(let clipID, let edge, _):
            let time = snapped(time(at: point.x), excluding: [clipID], disabled: noSnap)
            drag = .trim(clipID: clipID, edge: edge, time: time)
            needsDisplay = true
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = .none
            snapLine = nil
            needsDisplay = true
        }
        switch drag {
        case .move(let clipID, _, let start, let trackID, let insertIndex):
            guard let location = sequence.locate(clipID) else { return }
            let origin = sequence.tracks[location.track]
            let clip = origin.clips[location.clip]
            if let insertIndex {
                if origin.id == trackID, insertIndex == location.clip { return }
                editor.perform(.moveClip(clipID: clipID, toTrackID: trackID == origin.id ? nil : trackID, start: nil, index: insertIndex))
            } else if start != clip.start || trackID != origin.id {
                editor.perform(.moveClip(clipID: clipID, toTrackID: trackID, start: start, index: nil))
            }
        case .trim(let clipID, let edge, let time):
            guard let clip = sequence.clip(clipID), time != (edge == .start ? clip.start : clip.end) else { return }
            editor.perform(.trimClip(clipID: clipID, edge: edge, to: time))
        default:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func updateCursor(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (_, row, rect) = hit(point), !row.track.locked {
            let edgeZone = min(7, rect.width / 3)
            if point.x - rect.minX <= edgeZone || rect.maxX - point.x <= edgeZone {
                NSCursor.resizeLeftRight.set()
                return
            }
        }
        NSCursor.arrow.set()
    }

    // MARK: Zoom

    private func setZoom(_ value: Double, anchor: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clamped = min(600, max(6, value))
        let anchorTime = Double(anchor - TimelineNSView.headerWidth) / zoom
        let offsetInView = anchor - scroll.documentVisibleRect.minX
        editor.zoom = clamped
        zoom = clamped
        resizeToContent()
        let newX = TimelineNSView.headerWidth + CGFloat(anchorTime * clamped) - offsetInView
        scroll.contentView.scroll(to: CGPoint(x: max(0, min(newX, bounds.width - scroll.contentSize.width)), y: scroll.documentVisibleRect.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + Double(event.magnification)), anchor: convert(event.locationInWindow, from: nil).x)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            setZoom(zoom * (1 + Double(event.scrollingDeltaY) * 0.01), anchor: convert(event.locationInWindow, from: nil).x)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        func item(_ title: String, key: String = "", _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
            menu.addItem(entry)
        }
        if let (clip, _, _) = hit(point) {
            if !selection.contains(clip.id) { editor.selection = [clip.id] }
            item("Split at Playhead", key: "b") { [editor] in editor.splitAtPlayhead() }
            item("Duplicate", key: "d") { [editor] in editor.duplicateSelection() }
            menu.addItem(.separator())
            if clip.kind == .video, clip.linkedClipID == nil, editor.project.asset(clip.assetID)?.metadata.hasAudio == true {
                item("Detach Audio") { [editor] in editor.perform(.detachAudio(clipID: clip.id, newClipID: UUID(), newTrackID: UUID())) }
            }
            if clip.kind == .audio || (clip.kind == .video && editor.project.asset(clip.assetID)?.metadata.hasAudio == true) {
                item("Detect Beats") { [editor] in editor.detectBeats(forClip: clip.id) }
            }
            if clip.transitionIn != nil {
                item("Remove Transition") { [editor] in editor.perform(.setTransition(clipID: clip.id, transition: nil)) }
            } else if clip.kind != .audio {
                item("Add Dissolve") { [editor] in editor.perform(.setTransition(clipID: clip.id, transition: Transition(type: .dissolve))) }
            }
            menu.addItem(.separator())
            item("Delete") { [editor] in editor.deleteSelection(ripple: false) }
            item("Ripple Delete") { [editor] in editor.deleteSelection(ripple: true) }
        } else {
            let at = time(at: point.x)
            item("Add Marker Here") { [editor] in editor.perform(.addMarkers(sequenceID: nil, markers: [Marker(time: at)])) }
            if let marker = sequence.markers.first(where: { abs(x(for: $0.time) - point.x) < 6 && ($0.kind == .standard || $0.kind == .section) }) {
                item("Remove Marker") { [editor] in editor.perform(.removeMarkers(markerIDs: [marker.id])) }
            }
            if let row = row(at: point.y), row.track.kind != .main {
                item("Close Gaps on “\(row.track.name)”") { [editor] in editor.perform(.closeGaps(trackID: row.track.id)) }
                if row.track.clips.isEmpty {
                    item("Remove Track “\(row.track.name)”") { [editor] in editor.perform(.removeTrack(trackID: row.track.id)) }
                }
            }
            menu.addItem(.separator())
            item("Add Overlay Track") { [editor] in editor.perform(.addTrack(sequenceID: nil, trackID: UUID(), kind: .overlay, name: nil, index: nil)) }
            item("Add Audio Track") { [editor] in editor.perform(.addTrack(sequenceID: nil, trackID: UUID(), kind: .audio, name: nil, index: nil)) }
            item("Add Text Track") { [editor] in editor.perform(.addTrack(sequenceID: nil, trackID: UUID(), kind: .text, name: nil, index: nil)) }
        }
        return menu
    }

    // MARK: Drag and drop

    private func dropTarget(_ sender: NSDraggingInfo) -> (trackID: UUID?, time: RationalTime) {
        let point = convert(sender.draggingLocation, from: nil)
        return (row(at: point.y)?.track.id, time(at: point.x))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlight = dropTarget(sender)
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = dropTarget(sender)
        dropHighlight = nil
        needsDisplay = true
        let pasteboard = sender.draggingPasteboard
        if let text = pasteboard.string(forType: .string), text.hasPrefix(TimelineNSView.assetDragPrefix),
           let assetID = UUID(uuidString: String(text.dropFirst(TimelineNSView.assetDragPrefix.count))), let asset = editor.project.asset(assetID) {
            let kind: ClipKind = asset.kind == .audio ? .audio : asset.kind == .image ? .image : .video
            // Use the hovered track when it can hold this media; otherwise let Kirie choose.
            let track = sequence.tracks.first { $0.id == target.trackID && $0.kind.accepts(kind) && !$0.kind.isMagnetic }
            editor.addToTimeline(assetID, trackID: track?.id, start: track != nil || asset.kind == .audio ? target.time : nil)
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            editor.importFiles(urls, addToTimeline: true)
            return true
        }
        return false
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
