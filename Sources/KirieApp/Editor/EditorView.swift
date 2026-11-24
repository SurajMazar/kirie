import AppKit
import ProjectDomain
import SwiftUI

struct EditorView: View {
    @Bindable var editor: EditorModel
    @AppStorage("editor.showLibrary") private var showLibrary = true
    @AppStorage("editor.showInspector") private var showInspector = true
    @AppStorage("editor.timelineHeight") private var timelineHeight = 280.0
    @AppStorage("editor.trackScale") private var trackScale = 1.0
    @AppStorage("editor.storyboard") private var storyboard = false
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { geometry in
            // On narrow windows the side panels step aside so the preview and timeline keep their room.
            let narrow = geometry.size.width < 1040
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if showLibrary, !narrow || !showInspector {
                        LibraryPanel(editor: editor).frame(width: Theme.Size.library)
                        Divider1(vertical: true)
                    }
                    ViewerView(editor: editor).frame(minWidth: 280)
                    if showInspector {
                        Divider1(vertical: true)
                        InspectorView(editor: editor).frame(width: Theme.Size.inspector)
                    }
                }
                .frame(maxHeight: .infinity)
                ResizeHandle(height: $timelineHeight, range: 140...max(160, geometry.size.height - 220))
                timelineBar
                Divider1()
                Group {
                    if storyboard {
                        StoryboardView(editor: editor)
                    } else if editor.sequence.allClips.isEmpty {
                        EmptyTimeline(editor: editor)
                    } else {
                        TimelineView(editor: editor, sequence: editor.sequence, selection: editor.selection, playhead: editor.playhead, zoom: editor.zoom,
                                     trackScale: trackScale, cacheGeneration: editor.cache.generation, isPlaying: editor.player.isPlaying)
                    }
                }
                .frame(height: min(timelineHeight, max(140, geometry.size.height - 220)))
            }
        }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
    }

    // MARK: Timeline toolbar

    private var timelineBar: some View {
        HStack(spacing: Theme.Space.xs) {
            IconButton(symbol: "sidebar.left", label: showLibrary ? "Hide library" : "Show library", active: showLibrary) { showLibrary.toggle() }
            if editor.project.sequences.count > 1 {
                Picker("Timeline", selection: Binding(get: { editor.project.activeSequenceID }, set: { editor.activate($0) })) {
                    ForEach(editor.project.sequences) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 170).help("Switch timeline")
            } else {
                Text(editor.sequence.name).font(Theme.Font.label).foregroundStyle(Theme.secondary).padding(.horizontal, Theme.Space.xs)
            }
            Divider1(vertical: true).frame(height: 16).padding(.horizontal, Theme.Space.xs)
            IconButton(symbol: "scissors", label: "Split at playhead", shortcutHint: "⌘B") { editor.splitAtPlayhead() }
            IconButton(symbol: "plus.square.on.square", label: "Duplicate", shortcutHint: "⌘D") { editor.duplicateSelection() }.disabled(editor.selection.isEmpty)
            IconButton(symbol: "trash", label: "Delete", shortcutHint: "⌫") { editor.deleteSelection(ripple: false) }.disabled(editor.selection.isEmpty)
            IconButton(symbol: "arrow.left.to.line.compact", label: "Ripple delete", shortcutHint: "⇧⌫") { editor.deleteSelection(ripple: true) }.disabled(editor.selection.isEmpty)
            IconButton(symbol: "flag", label: "Add marker", shortcutHint: "M") { editor.addMarker() }
            Divider1(vertical: true).frame(height: 16).padding(.horizontal, Theme.Space.xs)
            IconButton(symbol: "arrow.right.and.line.vertical.and.arrow.left", label: editor.snapping ? "Snapping on" : "Snapping off", active: editor.snapping, shortcutHint: "N") {
                editor.snapping.toggle()
            }
            Menu {
                Button("Every beat") { editor.cutToBeat(every: 1) }
                Button("Every 2 beats") { editor.cutToBeat(every: 2) }
                Button("Every 4 beats (bar)") { editor.cutToBeat(every: 4) }
                Button("Every 8 beats") { editor.cutToBeat(every: 8) }
            } label: {
                Label("Cut to beat", systemImage: "metronome").font(Theme.Font.label)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(editor.sequence.beatTimes.isEmpty)
            .help(editor.sequence.beatTimes.isEmpty ? "Detect beats first: right-click a song on the timeline" : "Retime the selected main-track clips (or all of them) so cuts land on beats")
            Spacer()
            Text("\(editor.sequence.allClips.count) clip\(editor.sequence.allClips.count == 1 ? "" : "s") · \(formatDuration(editor.sequence.duration.seconds))")
                .font(Theme.Font.small).foregroundStyle(Theme.tertiary)
            IconButton(symbol: storyboard ? "rectangle.split.3x1.fill" : "rectangle.split.3x1", label: storyboard ? "Show timeline" : "Show storyboard", active: storyboard) {
                storyboard.toggle()
            }
            Menu {
                Picker("Track height", selection: $trackScale) {
                    Text("Compact").tag(0.75)
                    Text("Regular").tag(1.0)
                    Text("Tall").tag(1.4)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.and.down.text.horizontal")
            }
            .menuStyle(.borderlessButton).fixedSize().help("Track height")
            IconButton(symbol: "minus.magnifyingglass", label: "Zoom out", shortcutHint: "⌘−") { editor.zoom = max(6, editor.zoom / 1.4) }
            Slider(value: Binding(get: { log(editor.zoom) }, set: { editor.zoom = exp($0) }), in: log(6.0)...log(600.0)).frame(width: 90).controlSize(.mini)
                .accessibilityLabel("Timeline zoom")
            IconButton(symbol: "plus.magnifyingglass", label: "Zoom in", shortcutHint: "⌘=") { editor.zoom = min(600, editor.zoom * 1.4) }
            IconButton(symbol: "sidebar.right", label: showInspector ? "Hide inspector" : "Show inspector", active: showInspector) { showInspector.toggle() }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 34)
        .background(Theme.panel)
    }

    // MARK: Keyboard

    /// Single-key editing shortcuts. They are ignored while a text field is being edited.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            if NSApp.keyWindow?.attachedSheet != nil { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control])
            guard flags.isEmpty else { return event }
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 49: editor.player.togglePlay()                                  // space
            case 123: editor.player.step(frames: shift ? -Int64(editor.frameRate.fps.rounded()) : -1)   // ←
            case 124: editor.player.step(frames: shift ? Int64(editor.frameRate.fps.rounded()) : 1)     // →
            case 51, 117:                                                         // delete
                guard !editor.selection.isEmpty else { return event }
                editor.deleteSelection(ripple: shift)
            case 115: editor.player.seek(to: .zero)                               // home
            case 119: editor.player.seek(to: editor.sequence.duration)            // end
            case 53: editor.selection = []                                        // escape
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "j": editor.player.shuttle(-1)
                case "k": editor.player.shuttle(0)
                case "l": editor.player.shuttle(editor.player.player.rate > 0.9 ? 2 : 1)
                case "m": editor.addMarker()
                case "n": editor.snapping.toggle()
                case "b": editor.splitAtPlayhead()
                default: return event
                }
            }
            return nil
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Drag to resize the timeline.
struct ResizeHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
            .overlay(Rectangle().fill(Color.clear).frame(height: 9).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = start ?? height
                        start = base
                        height = min(range.upperBound, max(range.lowerBound, base - value.translation.height))
                    }
                    .onEnded { _ in start = nil }))
            .accessibilityLabel("Resize timeline")
    }
}

struct EmptyTimeline: View {
    let editor: EditorModel
    @State private var targeted = false

    var body: some View {
        EmptyState(symbol: "square.and.arrow.down.on.square", title: "The timeline is empty",
                   message: "Drop video, audio or pictures here, or double-click an item in the library. Pictures and video join the main track; audio gets its own track.",
                   actionTitle: "Import Media…") { editor.chooseFilesToImport(addToTimeline: true) }
            .background(targeted ? Theme.accentSoft : Theme.inset)
            .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
                handleDrop(providers, editor: editor)
                return true
            }
    }
}

/// Accepts files from Finder and assets dragged from the library.
@MainActor
func handleDrop(_ providers: [NSItemProvider], editor: EditorModel) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
        if provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { DispatchQueue.main.async { urls.append(url) } }
                DispatchQueue.main.async { group.leave() }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            group.enter()
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                DispatchQueue.main.async {
                    if let text = text as? String, text.hasPrefix(TimelineNSView.assetDragPrefix),
                       let id = UUID(uuidString: String(text.dropFirst(TimelineNSView.assetDragPrefix.count))) {
                        editor.addToTimeline(id)
                    }
                    group.leave()
                }
            }
        }
    }
    group.notify(queue: .main) { if !urls.isEmpty { editor.importFiles(urls, addToTimeline: true) } }
}

/// The main track as a row of cards: reorder scenes by dragging or with the arrow buttons. This is
/// the same sequence as the timeline, in a form that works well with the keyboard and VoiceOver.
struct StoryboardView: View {
    let editor: EditorModel
    @State private var dragging: UUID?

    var body: some View {
        let clips = editor.sequence.mainTrack?.clips ?? []
        if clips.isEmpty {
            EmptyTimeline(editor: editor)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        card(clip, index: index, count: clips.count)
                    }
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.inset)
        }
    }

    private func card(_ clip: Clip, index: Int, count: Int) -> some View {
        let selected = editor.selection.contains(clip.id)
        let asset = editor.project.asset(clip.assetID)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ZStack {
                Theme.panel
                if let asset, let image = editor.cache.thumbnail(for: asset, session: editor.session) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if let solid = clip.solidColor {
                    solid.color
                } else {
                    Image(systemName: clip.kind == .text ? "textformat" : "photo").foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
            Text("\(index + 1). \(clip.name)").font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1).frame(width: 104, alignment: .leading)
            HStack(spacing: 2) {
                Text(String(format: "%.1f s", clip.duration.seconds)).font(Theme.Font.small).foregroundStyle(Theme.secondary)
                if let transition = clip.transitionIn { Text("· \(transition.type.displayName)").font(Theme.Font.small).foregroundStyle(Theme.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
                IconButton(symbol: "chevron.left", label: "Move scene \(index + 1) earlier", size: 18) {
                    editor.perform(.moveClip(clipID: clip.id, toTrackID: nil, start: nil, index: index - 1))
                }
                .disabled(index == 0)
                IconButton(symbol: "chevron.right", label: "Move scene \(index + 1) later", size: 18) {
                    editor.perform(.moveClip(clipID: clip.id, toTrackID: nil, start: nil, index: index + 1))
                }
                .disabled(index == count - 1)
            }
            .frame(width: 104)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editor.selection = [clip.id]
            editor.player.seek(to: clip.start)
        }
        .onDrag {
            dragging = clip.id
            return NSItemProvider(object: "kirie-scene:\(clip.id.uuidString)" as NSString)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            guard let dragging, dragging != clip.id else { return false }
            editor.perform(.moveClip(clipID: dragging, toTrackID: nil, start: nil, index: index))
            self.dragging = nil
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scene \(index + 1), \(clip.name), \(String(format: "%.1f", clip.duration.seconds)) seconds")
    }
}
