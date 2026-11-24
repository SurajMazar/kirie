import AppKit
import Persistence
import ProjectDomain
import SwiftUI

struct InspectorView: View {
    @Bindable var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: title)
            Divider1()
            ScrollView {
                VStack(spacing: 0) {
                    if let clip = editor.primaryClip {
                        ClipInspector(editor: editor, clip: clip)
                    } else if editor.selection.count > 1 {
                        MultiSelectionInspector(editor: editor)
                    } else {
                        ProjectInspector(editor: editor)
                    }
                }
            }
        }
        .background(Theme.panel)
    }

    private var title: String {
        if let clip = editor.primaryClip {
            return switch clip.kind {
            case .video: "Video clip"
            case .image: "Picture"
            case .audio: "Audio clip"
            case .text: clip.text?.role == .caption ? "Caption" : clip.text?.role == .lyric ? "Lyric line" : "Text"
            case .solid: "Colour card"
            }
        }
        return editor.selection.count > 1 ? "\(editor.selection.count) clips" : "Project"
    }
}

// MARK: Clip

struct ClipInspector: View {
    let editor: EditorModel
    let clip: Clip

    private var local: RationalTime { (editor.playhead - clip.start).clamped(.zero, clip.duration) }
    private var asset: MediaAsset? { editor.project.asset(clip.assetID) }
    private var hasSound: Bool { clip.kind == .audio || (clip.kind == .video && asset?.metadata.hasAudio == true) }

    var body: some View {
        VStack(spacing: 0) {
            summary
            if clip.kind == .text { TextSection(editor: editor, clip: clip) }
            if clip.isVisual { transform }
            if clip.usesSourceTiming { speed }
            if hasSound { audio }
            if clip.isVisual { transition }
            if clip.kind == .video || clip.kind == .image {
                colour
                effects
                compositing
            }
            keyframes
        }
    }

    // MARK: Values, keyframe-aware

    /// Current value of an animatable property at the playhead.
    private func value(_ property: AnimatableProperty) -> Double { clip.value(of: property, at: local) }

    /// Sets a property. If it is keyframed, this edits (or adds) the keyframe at the playhead;
    /// otherwise it changes the clip's base value.
    private func set(_ property: AnimatableProperty, _ value: Double) {
        if clip.hasKeyframes(for: property) {
            let existing = clip.keyframes.first { $0.property == property && $0.time == local.rounded(toFrame: editor.frameRate) }
            let keyframe = Keyframe(id: existing?.id ?? UUID(), property: property, time: local, value: value, easing: existing?.easing ?? .easeInOut)
            editor.perform(.setKeyframe(clipID: clip.id, keyframe: keyframe), coalesce: "key-\(property.rawValue)-\(clip.id)")
            return
        }
        if property == .volume {
            var audio = clip.audio
            audio.gain = value
            editor.perform(.setClipAudio(clipID: clip.id, audio: audio), coalesce: "volume-\(clip.id)")
            return
        }
        var transform = clip.transform
        switch property {
        case .positionX: transform.position.x = value
        case .positionY: transform.position.y = value
        case .scale: transform.scale = value
        case .rotation: transform.rotation = value
        case .opacity: transform.opacity = value
        case .volume: break
        }
        editor.perform(.setTransform(clipID: clip.id, transform: transform), coalesce: "transform-\(property.rawValue)-\(clip.id)")
    }

    private func binding(_ property: AnimatableProperty) -> Binding<Double> {
        Binding(get: { value(property) }, set: { set(property, $0) })
    }

    private func animated(_ label: String, _ property: AnimatableProperty, range: ClosedRange<Double>, format: String = "%.0f", unit: String = "",
                          scale: Double = 1) -> some View {
        HStack(spacing: Theme.Space.xs) {
            PropertySlider(label: label, value: binding(property), range: range, format: format, unit: unit, displayScale: scale) { editing in
                if !editing { editor.endGesture() }
            }
            KeyframeToggle(editor: editor, clip: clip, property: property, local: local)
        }
    }

    private func setTransform(_ mutate: (inout ClipTransform) -> Void) {
        var transform = clip.transform
        mutate(&transform)
        editor.perform(.setTransform(clipID: clip.id, transform: transform))
    }

    private func setLook(coalesce: String? = nil, _ mutate: (inout Clip) -> Void) {
        var copy = clip
        mutate(&copy)
        editor.perform(.setLook(clipID: clip.id, color: copy.color, filters: copy.filters, blendMode: copy.blendMode, mask: copy.mask, chromaKey: copy.chromaKey),
                       coalesce: coalesce)
    }

    // MARK: Sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(clip.kind == .text ? (clip.text.map { LyricMarkup.plainText($0.string) } ?? clip.name) : clip.name)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
            HStack(spacing: Theme.Space.s) {
                Text("Starts \(Timecode.string(clip.start, rate: editor.frameRate))").font(Theme.Font.mono).foregroundStyle(Theme.secondary)
                Text(String(format: "%.2f s", clip.duration.seconds)).font(Theme.Font.mono).foregroundStyle(Theme.secondary)
            }
            if let asset, editor.missingMedia.contains(where: { $0.id == asset.id }) {
                HStack {
                    Label("Media offline", systemImage: "exclamationmark.triangle.fill").font(Theme.Font.label).foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Relink…") { editor.relink(asset) }.buttonStyle(.kirieCompact)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .overlay(alignment: .bottom) { Divider1() }
    }

    private var transform: some View {
        InspectorSection("Transform", trailing: AnyView(Button("Reset") {
            editor.perform([.clearKeyframes(clipID: clip.id, property: nil),
                            .setTransform(clipID: clip.id, transform: ClipTransform(crop: clip.transform.crop, fit: clip.transform.fit, backdrop: clip.transform.backdrop, backdropColor: clip.transform.backdropColor))],
                           label: "Reset transform")
        }.buttonStyle(.kirieQuiet).font(Theme.Font.small))) {
            animated("Position X", .positionX, range: -0.5...1.5, format: "%.1f", unit: "%", scale: 100)
            animated("Position Y", .positionY, range: -0.5...1.5, format: "%.1f", unit: "%", scale: 100)
            animated("Scale", .scale, range: 0.05...4, format: "%.0f", unit: "%", scale: 100)
            animated("Rotation", .rotation, range: -180...180, format: "%.1f", unit: "°")
            animated("Opacity", .opacity, range: 0...1, format: "%.0f", unit: "%", scale: 100)
            if clip.kind == .video || clip.kind == .image {
                PropertyRow(label: "Fit") {
                    Picker("Fit", selection: Binding(get: { clip.transform.fit }, set: { fit in setTransform { $0.fit = fit } })) {
                        Text("Fit").tag(FitMode.contain)
                        Text("Fill").tag(FitMode.cover)
                        Text("Stretch").tag(FitMode.fill)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                PropertyRow(label: "Behind") {
                    Picker("Backdrop", selection: Binding(get: { clip.transform.backdrop }, set: { backdrop in
                        setTransform { $0.backdrop = backdrop; if backdrop == .color, $0.backdropColor == nil { $0.backdropColor = .paper } }
                    })) {
                        Text("Canvas").tag(ClipBackdrop.none)
                        Text("Blur").tag(ClipBackdrop.blur)
                        Text("Colour").tag(ClipBackdrop.color)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    if clip.transform.backdrop == .color {
                        ColorPicker("Backdrop colour", selection: Binding(get: { (clip.transform.backdropColor ?? .paper).color },
                                                                          set: { color in setTransform { $0.backdropColor = RGBAColor(color) } }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                PropertyRow(label: "Flip") {
                    Toggle("Horizontal", isOn: Binding(get: { clip.transform.flipHorizontal }, set: { on in setTransform { $0.flipHorizontal = on } }))
                        .toggleStyle(.button).controlSize(.small)
                    Toggle("Vertical", isOn: Binding(get: { clip.transform.flipVertical }, set: { on in setTransform { $0.flipVertical = on } }))
                        .toggleStyle(.button).controlSize(.small)
                }
                CropControls(editor: editor, clip: clip)
            }
        }
    }

    private var speed: some View {
        InspectorSection("Speed") {
            PropertySlider(label: "Speed", value: Binding(get: { clip.speed }, set: { editor.perform(.setSpeed(clipID: clip.id, speed: $0), coalesce: "speed-\(clip.id)") }),
                           range: 0.1...8, format: "%.2f", unit: "×") { if !$0 { editor.endGesture() } }
            HStack(spacing: Theme.Space.xs) {
                ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { preset in
                    Button(String(format: "%g×", preset)) { editor.perform(.setSpeed(clipID: clip.id, speed: preset)) }.buttonStyle(.kirieCompact)
                }
            }
            Text("Pitch is preserved. Speeds up to 100× can be typed in.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
            PlannedNote(text: "Reverse, freeze frame and speed curves.")
        }
    }

    private var audio: some View {
        InspectorSection("Audio") {
            HStack(spacing: Theme.Space.xs) {
                PropertySlider(label: "Volume", value: binding(.volume), range: 0...4, format: "%.0f", unit: "%", displayScale: 100) { if !$0 { editor.endGesture() } }
                KeyframeToggle(editor: editor, clip: clip, property: .volume, local: local)
            }
            PropertySlider(label: "Fade in", value: Binding(get: { clip.audio.fadeIn.seconds }, set: { seconds in
                var audio = clip.audio; audio.fadeIn = RationalTime(seconds: seconds)
                editor.perform(.setClipAudio(clipID: clip.id, audio: audio), coalesce: "fadein-\(clip.id)")
            }), range: 0...min(5, clip.duration.seconds), format: "%.2f", unit: "s") { if !$0 { editor.endGesture() } }
            PropertySlider(label: "Fade out", value: Binding(get: { clip.audio.fadeOut.seconds }, set: { seconds in
                var audio = clip.audio; audio.fadeOut = RationalTime(seconds: seconds)
                editor.perform(.setClipAudio(clipID: clip.id, audio: audio), coalesce: "fadeout-\(clip.id)")
            }), range: 0...min(5, clip.duration.seconds), format: "%.2f", unit: "s") { if !$0 { editor.endGesture() } }
            HStack {
                Toggle("Mute", isOn: Binding(get: { clip.audio.muted }, set: { muted in
                    var audio = clip.audio; audio.muted = muted
                    editor.perform(.setClipAudio(clipID: clip.id, audio: audio))
                }))
                .toggleStyle(.checkbox).font(Theme.Font.label)
                Spacer()
                if clip.kind == .video, clip.linkedClipID == nil {
                    Button("Detach audio") { editor.perform(.detachAudio(clipID: clip.id, newClipID: UUID(), newTrackID: UUID())) }.buttonStyle(.kirieCompact)
                }
            }
            HStack {
                Button { editor.detectBeats(forClip: clip.id) } label: { Label("Detect beats", systemImage: "metronome") }.buttonStyle(.kirieCompact)
                if let bpm = asset?.bpm { Text(String(format: "%.0f BPM", bpm)).font(Theme.Font.mono).foregroundStyle(Theme.secondary) }
                Spacer()
                Button { editor.autoCaption(clipID: clip.id) } label: { Label("Auto captions", systemImage: "captions.bubble") }.buttonStyle(.kirieCompact)
                    .help("Transcribe this clip on this Mac. Audio never leaves your computer.")
            }
            if let asset {
                PropertyRow(label: "Rights") {
                    Picker("Rights", selection: Binding(get: { asset.rights.status }, set: { status in
                        var rights = asset.rights; rights.status = status
                        editor.perform(.updateAssetInfo(assetID: asset.id, name: nil, rights: rights, favourite: nil, rating: nil, keywords: nil, bpm: nil))
                    })) {
                        ForEach(RightsStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                }
                if asset.rights.status == .commercialUnlicensed {
                    Label("This audio plays in the preview but is left out of exports. Kirie writes a song note so you can add it in the app when you post.",
                          systemImage: "music.note.list").font(Theme.Font.small).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
            PlannedNote(text: "Noise reduction, voice enhance and ducking.")
        }
    }

    private var transition: some View {
        InspectorSection("Transition", expandedByDefault: clip.transitionIn != nil) {
            PropertyRow(label: "Into clip") {
                Picker("Transition", selection: Binding(get: { clip.transitionIn?.type }, set: { type in
                    if let type {
                        editor.perform(.setTransition(clipID: clip.id, transition: Transition(type: type, duration: clip.transitionIn?.duration ?? RationalTime(seconds: 0.45),
                                                                                              direction: clip.transitionIn?.direction ?? .left)))
                    } else {
                        editor.perform(.setTransition(clipID: clip.id, transition: nil))
                    }
                })) {
                    Text("Cut").tag(TransitionType?.none)
                    Divider()
                    ForEach(TransitionType.allCases.filter { !$0.isComic }, id: \.self) { Text($0.displayName).tag(TransitionType?.some($0)) }
                    Divider()
                    ForEach(TransitionType.allCases.filter(\.isComic), id: \.self) { Text($0.displayName).tag(TransitionType?.some($0)) }
                }
                .labelsHidden().controlSize(.small)
            }
            if let current = clip.transitionIn {
                PropertySlider(label: "Duration", value: Binding(get: { current.duration.seconds }, set: { seconds in
                    editor.perform(.setTransition(clipID: clip.id, transition: Transition(type: current.type, duration: RationalTime(seconds: seconds), direction: current.direction)),
                                   coalesce: "transition-\(clip.id)")
                }), range: 0.1...3, format: "%.2f", unit: "s") { if !$0 { editor.endGesture() } }
                if current.type.usesDirection {
                    PropertyRow(label: "Direction") {
                        Picker("Direction", selection: Binding(get: { current.direction }, set: { direction in
                            editor.perform(.setTransition(clipID: clip.id, transition: Transition(type: current.type, duration: current.duration, direction: direction)))
                        })) {
                            Image(systemName: "arrow.left").tag(Direction.left)
                            Image(systemName: "arrow.right").tag(Direction.right)
                            Image(systemName: "arrow.up").tag(Direction.up)
                            Image(systemName: "arrow.down").tag(Direction.down)
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    }
                }
                Text("On the main track a transition overlaps this clip with the one before it, and can be at most half as long as the shorter of the two.")
                    .font(Theme.Font.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func colourSlider(_ label: String, _ keyPath: WritableKeyPath<ColorAdjust, Double>, _ range: ClosedRange<Double>) -> some View {
        PropertySlider(label: label, value: Binding(get: { clip.color[keyPath: keyPath] }, set: { value in
            setLook(coalesce: "colour-\(label)-\(clip.id)") { $0.color[keyPath: keyPath] = value }
        }), range: range, format: "%.0f", displayScale: 100) { if !$0 { editor.endGesture() } }
    }

    private var colour: some View {
        InspectorSection("Colour", expandedByDefault: false, trailing: AnyView(Button("Reset") { setLook { $0.color = .neutral } }
            .buttonStyle(.kirieQuiet).font(Theme.Font.small).disabled(clip.color.isNeutral))) {
            colourSlider("Exposure", \.exposure, -2...2)
            colourSlider("Contrast", \.contrast, -1...1)
            colourSlider("Highlights", \.highlights, -1...1)
            colourSlider("Shadows", \.shadows, -1...1)
            colourSlider("Saturation", \.saturation, -1...1)
            colourSlider("Warmth", \.temperature, -1...1)
            colourSlider("Tint", \.tint, -1...1)
            colourSlider("Vignette", \.vignette, 0...1)
            colourSlider("Sharpen", \.sharpen, 0...1)
        }
    }

    private var effects: some View {
        InspectorSection("Effects", expandedByDefault: !clip.filters.isEmpty, trailing: AnyView(Menu {
            Section("Looks") { ForEach(FilterKind.allCases.filter(\.isLook), id: \.self) { kind in Button(kind.displayName) { setLook { $0.filters.append(AppliedFilter(kind: kind)) } } } }
            Section("Effects") { ForEach(FilterKind.allCases.filter { !$0.isLook }, id: \.self) { kind in Button(kind.displayName) { setLook { $0.filters.append(AppliedFilter(kind: kind)) } } } }
        } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Add an effect"))) {
            if clip.filters.isEmpty {
                Text("No effects. Add a look or an effect with +, or from the Effects tab.").font(Theme.Font.label).foregroundStyle(Theme.tertiary)
            }
            ForEach(Array(clip.filters.enumerated()), id: \.element.id) { index, filter in
                VStack(spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        Toggle(filter.kind.displayName, isOn: Binding(get: { filter.enabled }, set: { on in setLook { $0.filters[index].enabled = on } }))
                            .toggleStyle(.checkbox).font(Theme.Font.label)
                        Spacer()
                        IconButton(symbol: "chevron.up", label: "Move \(filter.kind.displayName) up", size: 18) { setLook { $0.filters.swapAt(index, index - 1) } }.disabled(index == 0)
                        IconButton(symbol: "chevron.down", label: "Move \(filter.kind.displayName) down", size: 18) { setLook { $0.filters.swapAt(index, index + 1) } }
                            .disabled(index == clip.filters.count - 1)
                        IconButton(symbol: "xmark", label: "Remove \(filter.kind.displayName)", size: 18) { setLook { $0.filters.remove(at: index) } }
                    }
                    PropertySlider(label: "Intensity", value: Binding(get: { filter.intensity }, set: { value in
                        setLook(coalesce: "filter-\(filter.id)") { $0.filters[index].intensity = value }
                    }), range: 0...1, format: "%.0f", unit: "%", displayScale: 100) { if !$0 { editor.endGesture() } }
                }
                .opacity(filter.enabled ? 1 : 0.55)
            }
        }
    }

    private var compositing: some View {
        InspectorSection("Compositing", expandedByDefault: false) {
            PropertyRow(label: "Blend") {
                Picker("Blend mode", selection: Binding(get: { clip.blendMode }, set: { mode in setLook { $0.blendMode = mode } })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst()).tag($0) }
                }
                .labelsHidden().controlSize(.small)
            }
            Toggle("Chroma key (green screen)", isOn: Binding(get: { clip.chromaKey != nil }, set: { on in setLook { $0.chromaKey = on ? ChromaKey() : nil } }))
                .toggleStyle(.checkbox).font(Theme.Font.label)
            if let key = clip.chromaKey {
                PropertyRow(label: "Key colour") {
                    ColorPicker("Key colour", selection: Binding(get: { key.color.color }, set: { color in setLook { $0.chromaKey?.color = RGBAColor(color) } }), supportsOpacity: false).labelsHidden()
                }
                PropertySlider(label: "Tolerance", value: Binding(get: { key.tolerance }, set: { value in setLook(coalesce: "key-tol-\(clip.id)") { $0.chromaKey?.tolerance = value } }),
                               range: 0.02...0.6, format: "%.0f", unit: "%", displayScale: 100) { if !$0 { editor.endGesture() } }
                PropertySlider(label: "Softness", value: Binding(get: { key.softness }, set: { value in setLook(coalesce: "key-soft-\(clip.id)") { $0.chromaKey?.softness = value } }),
                               range: 0...0.4, format: "%.0f", unit: "%", displayScale: 100) { if !$0 { editor.endGesture() } }
            }
            Toggle("Mask", isOn: Binding(get: { clip.mask != nil }, set: { on in setLook { $0.mask = on ? ClipMask() : nil } })).toggleStyle(.checkbox).font(Theme.Font.label)
            if let mask = clip.mask {
                PropertyRow(label: "Shape") {
                    Picker("Mask shape", selection: Binding(get: { mask.shape }, set: { shape in setLook { $0.mask?.shape = shape } })) {
                        ForEach(MaskShape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                    Toggle("Invert", isOn: Binding(get: { mask.inverted }, set: { on in setLook { $0.mask?.inverted = on } })).toggleStyle(.checkbox).font(Theme.Font.label)
                }
                PropertySlider(label: "Size", value: Binding(get: { mask.rect.width }, set: { size in
                    setLook(coalesce: "mask-size-\(clip.id)") { $0.mask?.rect = UnitRect(x: (1 - size) / 2, y: (1 - size) / 2, width: size, height: size) }
                }), range: 0.1...1, format: "%.0f", unit: "%", displayScale: 100) { if !$0 { editor.endGesture() } }
                PropertySlider(label: "Feather", value: Binding(get: { mask.feather }, set: { value in setLook(coalesce: "mask-feather-\(clip.id)") { $0.mask?.feather = value } }),
                               range: 0...1, format: "%.0f", unit: "%", displayScale: 100) { if !$0 { editor.endGesture() } }
            }
        }
    }

    private var keyframes: some View {
        InspectorSection("Keyframes", expandedByDefault: !clip.keyframes.isEmpty, trailing: AnyView(Button("Clear") { editor.perform(.clearKeyframes(clipID: clip.id, property: nil)) }
            .buttonStyle(.kirieQuiet).font(Theme.Font.small).disabled(clip.keyframes.isEmpty))) {
            if clip.keyframes.isEmpty {
                Text("Click the diamond beside a property to add a keyframe at the playhead. Change the value at another time to animate between them.")
                    .font(Theme.Font.label).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(clip.keyframes.sorted { $0.property.rawValue == $1.property.rawValue ? $0.time < $1.time : $0.property.rawValue < $1.property.rawValue }) { keyframe in
                HStack(spacing: Theme.Space.xs) {
                    Button {
                        editor.player.seek(to: clip.start + keyframe.time)
                    } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Image(systemName: "diamond.fill").font(.system(size: 7)).foregroundStyle(Theme.accent)
                            Text(keyframe.property.displayName).font(Theme.Font.label).foregroundStyle(Theme.text)
                            Text(String(format: "%.2fs", keyframe.time.seconds)).font(Theme.Font.mono).foregroundStyle(Theme.secondary)
                        }
                    }
                    .buttonStyle(.plain).help("Go to this keyframe")
                    Spacer()
                    Picker("Easing", selection: Binding(get: { keyframe.easing }, set: { easing in
                        var updated = keyframe; updated.easing = easing
                        editor.perform(.setKeyframe(clipID: clip.id, keyframe: updated))
                    })) {
                        ForEach(Easing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().controlSize(.mini).frame(width: 86)
                    IconButton(symbol: "xmark", label: "Remove keyframe", size: 18) { editor.perform(.removeKeyframe(clipID: clip.id, keyframeID: keyframe.id)) }
                }
            }
        }
    }
}

/// Diamond button: adds a keyframe for a property at the playhead, or removes the one that is there.
struct KeyframeToggle: View {
    let editor: EditorModel
    let clip: Clip
    let property: AnimatableProperty
    let local: RationalTime

    var body: some View {
        let time = local.rounded(toFrame: editor.frameRate)
        let here = clip.keyframes.first { $0.property == property && $0.time == time }
        let animated = clip.hasKeyframes(for: property)
        Button {
            if let here {
                editor.perform(.removeKeyframe(clipID: clip.id, keyframeID: here.id))
            } else {
                editor.perform(.setKeyframe(clipID: clip.id, keyframe: Keyframe(property: property, time: time, value: clip.value(of: property, at: local))))
            }
        } label: {
            Image(systemName: here != nil ? "diamond.fill" : "diamond").font(.system(size: 10))
                .foregroundStyle(here != nil ? Theme.accent : animated ? Theme.accent.opacity(0.6) : Theme.tertiary)
                .frame(width: 18, height: Theme.Size.controlCompact).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(here != nil ? "Remove the \(property.displayName.lowercased()) keyframe here" : "Add a \(property.displayName.lowercased()) keyframe at the playhead")
        .accessibilityLabel(here != nil ? "Remove \(property.displayName) keyframe" : "Add \(property.displayName) keyframe")
    }
}

struct CropControls: View {
    let editor: EditorModel
    let clip: Clip
    @State private var open = false

    private func edge(_ label: String, get: @escaping (UnitRect) -> Double, set: @escaping (inout UnitRect, Double) -> Void) -> some View {
        PropertySlider(label: label, value: Binding(get: { get(clip.transform.crop) }, set: { value in
            var transform = clip.transform
            set(&transform.crop, value)
            transform.crop = transform.crop.clamped(minSize: 0.05)
            editor.perform(.setTransform(clipID: clip.id, transform: transform), coalesce: "crop-\(label)-\(clip.id)")
        }), range: 0...0.9, format: "%.0f", unit: "%", displayScale: 100) { if !$0 { editor.endGesture() } }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(spacing: Theme.Space.xs) {
                edge("Left", get: { $0.x }, set: { rect, value in let right = rect.maxX; rect.x = min(value, right - 0.05); rect.width = right - rect.x })
                edge("Top", get: { $0.y }, set: { rect, value in let bottom = rect.maxY; rect.y = min(value, bottom - 0.05); rect.height = bottom - rect.y })
                edge("Right", get: { 1 - $0.maxX }, set: { rect, value in rect.width = max(0.05, 1 - value - rect.x) })
                edge("Bottom", get: { 1 - $0.maxY }, set: { rect, value in rect.height = max(0.05, 1 - value - rect.y) })
            }
            .padding(.top, Theme.Space.xs)
        } label: {
            Text(clip.transform.crop == .full ? "Crop" : "Crop (active)").font(Theme.Font.label).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: Text

struct TextSection: View {
    let editor: EditorModel
    let clip: Clip
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var content: TextContent { clip.text ?? TextContent(string: "") }

    private func update(coalesce: String? = nil, _ mutate: (inout TextContent) -> Void) {
        var next = content
        mutate(&next)
        editor.perform(.setText(clipID: clip.id, text: next), coalesce: coalesce)
    }

    private var family: String { NSFont(name: content.style.fontName, size: 12)?.familyName ?? content.style.fontName }
    private var isBold: Bool { NSFont(name: content.style.fontName, size: 12).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false }

    private func setFont(family: String, bold: Bool) {
        let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: 12)
        update { $0.style.fontName = font?.fontName ?? family }
    }

    var body: some View {
        InspectorSection(content.role == .lyric ? "Lyric" : "Text") {
            TextEditor(text: $draft)
                .font(Theme.Font.body).scrollContentBackground(.hidden)
                .frame(minHeight: 54, maxHeight: 110)
                .padding(Theme.Space.xs)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(focused ? Theme.accent : Theme.border))
                .focused($focused)
                .onAppear { draft = content.string }
                .onChange(of: clip.id) { _, _ in draft = content.string }
                .onChange(of: content.string) { _, new in if !focused { draft = new } }
                .onChange(of: draft) { _, new in if focused, new != content.string { update(coalesce: "text-\(clip.id)") { $0.string = new } } }
                .onChange(of: focused) { _, isFocused in if !isFocused { editor.endGesture() } }
                .accessibilityLabel("Text")
            if content.role == .lyric {
                Text("*word* makes a word big. / starts a new row.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                PropertyRow(label: "Style") {
                    Picker("Lyric style", selection: Binding(get: { content.lyric?.style ?? .verse }, set: { style in
                        update { $0.lyric?.style = style; $0.style = ComicBuilder.lyricTextStyle(for: style) }
                    })) {
                        ForEach(LyricStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
            }
            PropertyRow(label: "Font") {
                Picker("Font", selection: Binding(get: { family }, set: { setFont(family: $0, bold: isBold) })) {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: 130)
                Toggle("B", isOn: Binding(get: { isBold }, set: { setFont(family: family, bold: $0) })).toggleStyle(.button).controlSize(.small).help("Bold")
            }
            PropertySlider(label: "Size", value: Binding(get: { content.style.fontSize }, set: { size in update(coalesce: "font-size-\(clip.id)") { $0.style.fontSize = size } }),
                           range: 16...320, format: "%.0f") { if !$0 { editor.endGesture() } }
            PropertyRow(label: "Colour") {
                ColorPicker("Text colour", selection: Binding(get: { content.style.color.color }, set: { color in update(coalesce: "text-colour-\(clip.id)") { $0.style.color = RGBAColor(color) } })).labelsHidden()
                Text("Outline").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                ColorPicker("Outline colour", selection: Binding(get: { content.style.strokeColor.color }, set: { color in update(coalesce: "stroke-colour-\(clip.id)") { $0.style.strokeColor = RGBAColor(color) } })).labelsHidden()
                if content.role != .title || content.animation == .karaoke {
                    Text("Highlight").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                    ColorPicker("Highlight colour", selection: Binding(get: { content.style.highlightColor.color }, set: { color in update(coalesce: "hl-colour-\(clip.id)") { $0.style.highlightColor = RGBAColor(color) } })).labelsHidden()
                }
            }
            PropertySlider(label: "Outline", value: Binding(get: { content.style.strokeWidth }, set: { width in update(coalesce: "stroke-\(clip.id)") { $0.style.strokeWidth = width } }),
                           range: 0...24, format: "%.0f") { if !$0 { editor.endGesture() } }
            if content.role != .lyric {
                PropertyRow(label: "Align") {
                    Picker("Alignment", selection: Binding(get: { content.style.alignment }, set: { alignment in update { $0.style.alignment = alignment } })) {
                        Image(systemName: "text.alignleft").tag(ProjectDomain.TextAlignment.left)
                        Image(systemName: "text.aligncenter").tag(ProjectDomain.TextAlignment.center)
                        Image(systemName: "text.alignright").tag(ProjectDomain.TextAlignment.right)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 96)
                    Toggle("CAPS", isOn: Binding(get: { content.style.allCaps }, set: { on in update { $0.style.allCaps = on } })).toggleStyle(.button).controlSize(.small)
                }
                PropertyRow(label: "Animation") {
                    Picker("Animation", selection: Binding(get: { content.animation }, set: { animation in update { $0.animation = animation } })) {
                        ForEach(TextAnimation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                }
                HStack {
                    Toggle("Shadow", isOn: Binding(get: { content.style.shadow != nil }, set: { on in update { $0.style.shadow = on ? TextShadow() : nil } })).toggleStyle(.checkbox).font(Theme.Font.label)
                    Toggle("Background", isOn: Binding(get: { content.style.background != nil }, set: { on in update { $0.style.background = on ? TextBackground() : nil } }))
                        .toggleStyle(.checkbox).font(Theme.Font.label)
                    if let background = content.style.background {
                        ColorPicker("Background colour", selection: Binding(get: { background.color.color }, set: { color in update(coalesce: "bg-colour-\(clip.id)") { $0.style.background?.color = RGBAColor(color) } })).labelsHidden()
                    }
                }
            }
            PlannedNote(text: "Gradient fills and curved text.")
        }
    }
}

// MARK: Nothing or many selected

struct MultiSelectionInspector: View {
    let editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("\(editor.selection.count) clips selected").font(Theme.Font.body).foregroundStyle(Theme.text)
            Text(String(format: "Total length %.2f s", editor.selectedClips.reduce(0) { $0 + $1.duration.seconds })).font(Theme.Font.label).foregroundStyle(Theme.secondary)
            HStack {
                Button("Duplicate") { editor.duplicateSelection() }.buttonStyle(.kirie)
                Button("Delete") { editor.deleteSelection(ripple: false) }.buttonStyle(.kirie)
                Button("Ripple delete") { editor.deleteSelection(ripple: true) }.buttonStyle(.kirie)
            }
            Text("Select a single clip to edit its properties.").font(Theme.Font.label).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
    }
}

struct ProjectInspector: View {
    @Bindable var editor: EditorModel
    @State private var name = ""
    @State private var snapshots: [SnapshotInfo] = []
    @State private var snapshotName = ""

    var body: some View {
        VStack(spacing: 0) {
            InspectorSection("Project") {
                KirieField(placeholder: "Project name", text: $name) {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty, name != editor.project.name { editor.perform(.renameProject(name: name)) }
                }
                .onAppear { name = editor.project.name }
                .onChange(of: editor.project.name) { _, new in name = new }
                Text("Nothing is selected. Click a clip on the timeline to edit it.").font(Theme.Font.label).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            InspectorSection("Canvas") {
                PropertyRow(label: "Size") {
                    Picker("Canvas", selection: Binding(get: { CanvasPreset.all.first { $0.width == editor.project.canvas.width && $0.height == editor.project.canvas.height }?.id ?? "custom" },
                                                        set: { id in
                        guard let preset = CanvasPreset.named(id) else { return }
                        var canvas = editor.project.canvas
                        canvas.width = preset.width; canvas.height = preset.height
                        editor.perform(.setCanvas(canvas: canvas))
                    })) {
                        ForEach(CanvasPreset.all) { Text("\($0.name) \($0.ratioLabel)").tag($0.id) }
                        if !CanvasPreset.all.contains(where: { $0.width == editor.project.canvas.width && $0.height == editor.project.canvas.height }) {
                            Text("Custom").tag("custom")
                        }
                    }
                    .labelsHidden().controlSize(.small)
                }
                Text(verbatim: "\(editor.project.canvas.width) × \(editor.project.canvas.height) · \(editor.project.canvas.frameRate.description) fps · \(editor.project.canvas.colorSpace.displayName)")
                    .font(Theme.Font.mono).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                PropertyRow(label: "Frame rate") {
                    Picker("Frame rate", selection: Binding(get: { editor.project.canvas.frameRate }, set: { rate in
                        var canvas = editor.project.canvas; canvas.frameRate = rate
                        editor.perform(.setCanvas(canvas: canvas))
                    })) {
                        ForEach(FrameRate.common, id: \.self) { Text("\($0.description) fps").tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                }
                PropertyRow(label: "Background") {
                    ColorPicker("Canvas background", selection: Binding(get: { editor.project.canvas.background.color }, set: { color in
                        var canvas = editor.project.canvas; canvas.background = RGBAColor(color)
                        editor.perform(.setCanvas(canvas: canvas), coalesce: "canvas-background")
                    }), supportsOpacity: false).labelsHidden()
                }
            }
            InspectorSection("Timeline") {
                PropertyRow(label: "Length") { Text(Timecode.string(editor.sequence.duration, rate: editor.frameRate)).font(Theme.Font.mono).foregroundStyle(Theme.text) }
                PropertyRow(label: "Tracks") { Text("\(editor.sequence.tracks.count)").font(Theme.Font.mono).foregroundStyle(Theme.text) }
                PropertyRow(label: "Markers") { Text("\(editor.sequence.markers.count) (\(editor.sequence.beatTimes.count) beats)").font(Theme.Font.mono).foregroundStyle(Theme.text) }
                if !editor.sequence.beatTimes.isEmpty {
                    Button("Remove beat markers") { editor.perform(.replaceBeatMarkers(sequenceID: nil, markers: [])) }.buttonStyle(.kirieCompact)
                }
            }
            if !editor.missingMedia.isEmpty {
                InspectorSection("Missing media") {
                    ForEach(editor.missingMedia) { asset in
                        HStack {
                            Label(asset.name, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.label).foregroundStyle(Theme.warning).lineLimit(1)
                            Spacer()
                            Button("Relink…") { editor.relink(asset) }.buttonStyle(.kirieCompact)
                        }
                    }
                }
            }
            InspectorSection("Snapshots", expandedByDefault: false) {
                HStack {
                    KirieField(placeholder: "Snapshot name", text: $snapshotName)
                    Button("Save") {
                        editor.createSnapshot(named: snapshotName.isEmpty ? "Snapshot" : snapshotName)
                        snapshotName = ""
                        snapshots = editor.session.package.listSnapshots()
                    }
                    .buttonStyle(.kirieCompact)
                }
                if snapshots.isEmpty { Text("No snapshots yet. Kirie also keeps automatic ones when you open a project and before each export.").font(Theme.Font.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true) }
                ForEach(snapshots.prefix(12)) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snapshot.name).font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))\(snapshot.automatic ? " · automatic" : "")").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                        }
                        Spacer()
                        Button("Restore") {
                            editor.restore(snapshot)
                            snapshots = editor.session.package.listSnapshots()
                        }
                        .buttonStyle(.kirieCompact)
                    }
                }
            }
            .onAppear { snapshots = editor.session.package.listSnapshots() }
        }
    }
}
