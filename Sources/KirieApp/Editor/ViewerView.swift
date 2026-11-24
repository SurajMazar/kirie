import AVFoundation
import AppKit
import ProjectDomain
import SwiftUI

/// Hosts the AVPlayerLayer. The picture comes from the same GPU compositor that export uses.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

struct ViewerView: View {
    @Bindable var editor: EditorModel
    @State private var timecodeText = ""
    @State private var editingTimecode = false
    @FocusState private var timecodeFocused: Bool

    private var aspect: CGFloat { CGFloat(editor.project.canvas.width) / CGFloat(max(1, editor.project.canvas.height)) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let fitted = fit(aspect, in: CGSize(width: geometry.size.width - 32, height: geometry.size.height - 24))
                ZStack {
                    Theme.inset
                    if editor.sequence.duration.isPositive {
                        ZStack {
                            Color.black
                            PlayerLayerView(player: editor.player.player)
                            SafeZoneOverlay(zone: editor.safeZone)
                            TransformOverlay(editor: editor, canvasSize: fitted)
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay(Rectangle().strokeBorder(Theme.border))
                        .accessibilityElement()
                        .accessibilityLabel("Preview of \(editor.sequence.name) at \(Timecode.string(editor.playhead, rate: editor.frameRate))")
                    } else {
                        EmptyState(symbol: "play.rectangle", title: "Nothing to preview yet",
                                   message: "Import media and add it to the timeline. Drag files straight from Finder onto the timeline below.",
                                   actionTitle: "Import Media…") { editor.chooseFilesToImport(addToTimeline: true) }
                    }
                    if let error = editor.player.buildError {
                        Label(error, systemImage: "exclamationmark.triangle").font(Theme.Font.label).foregroundStyle(Theme.warning)
                            .padding(Theme.Space.s).background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.elevated))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(Theme.Space.s)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            Divider1()
            transport
        }
        .background(Theme.inset)
    }

    private func fit(_ aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, size.height * aspect)
        return CGSize(width: max(1, width), height: max(1, width / aspect))
    }

    private var transport: some View {
        HStack(spacing: Theme.Space.s) {
            // Timecode: click to type a time and jump there.
            TextField("", text: $timecodeText)
                .textFieldStyle(.plain).font(Theme.Font.timecode).foregroundStyle(Theme.text)
                .frame(width: 96).multilineTextAlignment(.leading)
                .focused($timecodeFocused)
                .onSubmit {
                    if let time = Timecode.parse(timecodeText, rate: editor.frameRate) { editor.player.seek(to: time) }
                    timecodeFocused = false
                }
                .onChange(of: editor.playhead) { _, new in if !timecodeFocused { timecodeText = Timecode.string(new, rate: editor.frameRate) } }
                .onAppear { timecodeText = Timecode.string(editor.playhead, rate: editor.frameRate) }
                .help("Current time. Type a timecode and press Return to jump.")
                .accessibilityLabel("Current timecode")
            Text("/ \(Timecode.string(editor.sequence.duration, rate: editor.frameRate))").font(Theme.Font.mono).foregroundStyle(Theme.tertiary)
            Spacer()
            IconButton(symbol: "backward.end.fill", label: "Go to start", shortcutHint: "⌘←") { editor.player.seek(to: .zero) }
            IconButton(symbol: "backward.frame.fill", label: "Previous frame", shortcutHint: "←") { editor.player.step(frames: -1) }
            IconButton(symbol: editor.player.isPlaying ? "pause.fill" : "play.fill", label: editor.player.isPlaying ? "Pause" : "Play", size: 32, shortcutHint: "Space") {
                editor.player.togglePlay()
            }
            IconButton(symbol: "forward.frame.fill", label: "Next frame", shortcutHint: "→") { editor.player.step(frames: 1) }
            IconButton(symbol: "forward.end.fill", label: "Go to end", shortcutHint: "⌘→") { editor.player.seek(to: editor.sequence.duration) }
            Spacer()
            IconButton(symbol: "camera", label: "Save this frame as a PNG") { editor.saveFrame() }.disabled(editor.sequence.duration.isZero)
            Menu {
                Picker("Safe zones", selection: $editor.safeZone) {
                    ForEach(SafeZone.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(editor.safeZone == .off ? "Safe zones" : editor.safeZone.label, systemImage: "rectangle.dashed").font(Theme.Font.label)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Show where a platform's interface covers the video (approximate)")
            Menu {
                Picker("Preview quality", selection: $editor.quality) {
                    ForEach(PreviewQuality.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(editor.quality.label, systemImage: "sparkles.tv").font(Theme.Font.label)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Preview quality. Export always uses full quality.")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 40)
        .background(Theme.panel)
    }
}

/// Shaded areas where a platform's interface sits on top of the video.
struct SafeZoneOverlay: View {
    let zone: SafeZone

    var body: some View {
        if zone != .off {
            GeometryReader { geometry in
                let insets = zone.insets
                let w = geometry.size.width, h = geometry.size.height
                ZStack(alignment: .topLeading) {
                    Group {
                        Rectangle().frame(width: w, height: h * insets.top)
                        Rectangle().frame(width: w, height: h * insets.bottom).offset(y: h * (1 - insets.bottom))
                        Rectangle().frame(width: w * insets.trailing, height: h * 0.34).offset(x: w * (1 - insets.trailing), y: h * (1 - insets.bottom - 0.34))
                    }
                    .foregroundStyle(Theme.warning.opacity(0.22))
                    Rectangle().strokeBorder(Theme.warning.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .frame(width: w * (1 - insets.trailing), height: h * (1 - insets.top - insets.bottom))
                        .offset(y: h * insets.top)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Selection outline and direct manipulation for the selected clip: drag to move, drag the corner to scale.
struct TransformOverlay: View {
    let editor: EditorModel
    let canvasSize: CGSize
    @State private var dragStart: ClipTransform?

    var body: some View {
        if let clip = editor.primaryClip, clip.isVisual, clip.range.contains(editor.playhead) || clip.end == editor.playhead,
           !(clip.text?.role == .lyric) {
            let local = editor.playhead - clip.start
            let center = CGPoint(x: clip.value(of: .positionX, at: local) * canvasSize.width, y: clip.value(of: .positionY, at: local) * canvasSize.height)
            let box = boxSize(clip, scale: clip.value(of: .scale, at: local))
            ZStack {
                Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let start = dragStart ?? clip.transform
                            dragStart = start
                            var next = start
                            next.position = UnitPoint2D(x: start.position.x + value.translation.width / canvasSize.width,
                                                        y: start.position.y + value.translation.height / canvasSize.height)
                            // Snap to the canvas centre lines.
                            if abs(next.position.x - 0.5) < 0.012 { next.position.x = 0.5 }
                            if abs(next.position.y - 0.5) < 0.012 { next.position.y = 0.5 }
                            editor.perform(.setTransform(clipID: clip.id, transform: next), coalesce: "viewer-move-\(clip.id)")
                        }
                        .onEnded { _ in dragStart = nil; editor.endGesture() })
                Circle().fill(Theme.accent).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .offset(x: box.width / 2, y: box.height / 2)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStart ?? clip.transform
                            dragStart = start
                            let base = max(40, hypot(box.width, box.height) / 2 / max(0.01, clip.transform.scale) * start.scale)
                            let growth = (value.translation.width + value.translation.height) / 2
                            var next = start
                            next.scale = min(20, max(0.05, start.scale * (1 + growth / base)))
                            editor.perform(.setTransform(clipID: clip.id, transform: next), coalesce: "viewer-scale-\(clip.id)")
                        }
                        .onEnded { _ in dragStart = nil; editor.endGesture() })
                    .help("Drag to scale")
            }
            .rotationEffect(.degrees(clip.value(of: .rotation, at: local)))
            .position(center)
            .accessibilityHidden(true)
        }
    }

    /// On-screen size of the selected clip's picture or text block.
    private func boxSize(_ clip: Clip, scale: Double) -> CGSize {
        if clip.kind == .text {
            let style = clip.text?.style ?? .title
            let lines = max(1, (clip.text?.string.split(separator: "\n").count ?? 1))
            let width = min(canvasSize.width * style.maxWidth, CGFloat(clip.text?.string.count ?? 4) * style.fontSize * 0.6 * canvasSize.width / 1080)
            return CGSize(width: max(40, width * scale), height: max(20, CGFloat(lines) * style.fontSize * 1.3 * canvasSize.width / 1080 * scale))
        }
        var aspect = canvasSize.width / max(1, canvasSize.height)
        if let asset = editor.project.asset(clip.assetID) {
            aspect = CGFloat(Double(max(1, asset.metadata.displayWidth)) * clip.transform.crop.width) /
                CGFloat(Double(max(1, asset.metadata.displayHeight)) * clip.transform.crop.height)
        }
        let canvasAspect = canvasSize.width / max(1, canvasSize.height)
        var size: CGSize
        switch clip.transform.fit {
        case .fill: size = canvasSize
        case .contain: size = aspect > canvasAspect ? CGSize(width: canvasSize.width, height: canvasSize.width / aspect) : CGSize(width: canvasSize.height * aspect, height: canvasSize.height)
        case .cover: size = aspect > canvasAspect ? CGSize(width: canvasSize.height * aspect, height: canvasSize.height) : CGSize(width: canvasSize.width, height: canvasSize.width / aspect)
        }
        size.width *= scale
        size.height *= scale
        return size
    }
}
