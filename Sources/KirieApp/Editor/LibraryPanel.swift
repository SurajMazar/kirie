import AppKit
import KirieServices
import ProjectDomain
import SwiftUI

enum LibraryTab: String, CaseIterable, Identifiable {
    case media, audio, text, captions, transitions, effects
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .audio: "waveform"
        case .text: "textformat"
        case .captions: "captions.bubble"
        case .transitions: "arrow.left.arrow.right.square"
        case .effects: "wand.and.stars"
        }
    }
}

/// The editor's left panel: everything that can be added to the timeline.
struct LibraryPanel: View {
    @Bindable var editor: EditorModel
    @AppStorage("editor.libraryTab") private var tabRaw = LibraryTab.media.rawValue

    private var tab: LibraryTab { LibraryTab(rawValue: tabRaw) ?? .media }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(LibraryTab.allCases) { item in
                    IconButton(symbol: item.symbol, label: item.title, active: tab == item, size: 30) { tabRaw = item.rawValue }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 38)
            Divider1()
            switch tab {
            case .media: MediaTab(editor: editor)
            case .audio: AudioTab(editor: editor)
            case .text: TextTab(editor: editor)
            case .captions: CaptionsTab(editor: editor)
            case .transitions: TransitionsTab(editor: editor)
            case .effects: EffectsTab(editor: editor)
            }
        }
        .background(Theme.panel)
    }
}

struct TabHeader: View {
    let title: String
    var trailing: AnyView?
    var body: some View {
        HStack {
            Text(title.uppercased()).font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 30)
    }
}

struct AssetThumbnail: View {
    let editor: EditorModel
    let asset: MediaAsset

    var body: some View {
        ZStack {
            Theme.inset
            if asset.kind == .audio {
                Image(systemName: "waveform").font(.system(size: 18)).foregroundStyle(Theme.tertiary)
            } else if let image = editor.cache.thumbnail(for: asset, session: editor.session) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
            if editor.missingMedia.contains(where: { $0.id == asset.id }) {
                Theme.warningSoft
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
        }
    }
}

struct MediaTab: View {
    @Bindable var editor: EditorModel
    @State private var search = ""
    @State private var dropping = false

    private var assets: [MediaAsset] {
        editor.project.assets.filter { $0.kind != .audio && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Media", trailing: AnyView(Button { editor.chooseFilesToImport() } label: { Label("Import", systemImage: "plus") }
                .buttonStyle(.kirieCompact).help("Import media (⌘I)")))
            if editor.project.assets.contains(where: { $0.kind != .audio }) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    TextField("Search media", text: $search).textFieldStyle(.plain).font(Theme.Font.label)
                }
                .padding(.horizontal, Theme.Space.s).frame(height: Theme.Size.controlCompact)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.inset))
                .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                        ForEach(assets) { asset in tile(asset) }
                    }
                    .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.m)
                    if assets.isEmpty { Text("Nothing matches “\(search)”.").font(Theme.Font.label).foregroundStyle(Theme.tertiary).padding() }
                }
            } else {
                EmptyState(symbol: "photo.on.rectangle", title: "No media yet", message: "Import video and pictures, or drop them here from Finder.",
                           actionTitle: "Import Media…") { editor.chooseFilesToImport() }
            }
        }
        .background(dropping ? Theme.accentSoft : .clear)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in providers where provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { editor.importFiles(urls) }
            return true
        }
    }

    private func tile(_ asset: MediaAsset) -> some View {
        let selected = editor.selectedAssetID == asset.id
        return VStack(alignment: .leading, spacing: 3) {
            AssetThumbnail(editor: editor, asset: asset).frame(height: 78).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if asset.kind == .video {
                        Text(formatDuration(asset.metadata.duration.seconds)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 3).background(Capsule().fill(.black.opacity(0.6))).padding(3)
                    }
                }
            Text(asset.name).font(Theme.Font.small).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editor.addToTimeline(asset.id) }
        .onTapGesture { editor.selectedAssetID = asset.id }
        .onDrag { NSItemProvider(object: "\(TimelineNSView.assetDragPrefix)\(asset.id.uuidString)" as NSString) }
        .contextMenu {
            Button("Add to Timeline") { editor.addToTimeline(asset.id) }
            Button("Add as Overlay at Playhead") { editor.addOverlay(asset.id) }
            if asset.kind == .image { Button("Use as Comic Strip") { useAsStrip(asset) } }
            Divider()
            Button("Show in Finder") { if let url = editor.session.resolver.url(for: asset) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Button("Remove from Project") { editor.perform(.removeAsset(assetID: asset.id)) }
        }
        .help("\(asset.name)\n\(asset.metadata.displayWidth)×\(asset.metadata.displayHeight)\nDouble-click to add, or drag onto the timeline")
        .accessibilityLabel("\(asset.name), \(asset.kind.rawValue)")
        .accessibilityAction(named: "Add to timeline") { editor.addToTimeline(asset.id) }
    }

    private func useAsStrip(_ asset: MediaAsset) {
        do {
            let strip = try editor.session.addStrip(assetID: asset.id)
            editor.syncFromSession(reload: false)
            editor.notify(.success, "Found \(strip.panels.count) panel\(strip.panels.count == 1 ? "" : "s"). Open Comic Studio to review them.")
        } catch { editor.report(error) }
    }
}

struct AudioTab: View {
    @Bindable var editor: EditorModel

    private var assets: [MediaAsset] { editor.project.assets.filter { $0.kind == .audio } }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Audio", trailing: AnyView(Button { editor.chooseFilesToImport() } label: { Label("Import", systemImage: "plus") }.buttonStyle(.kirieCompact)))
            if assets.isEmpty {
                EmptyState(symbol: "waveform", title: "No audio yet", message: "Import a song or a voiceover. Kirie finds the beat on this Mac so cuts can land on it.",
                           actionTitle: "Import Audio…") { editor.chooseFilesToImport() }
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(assets) { asset in row(asset) }
                        if !editor.sequence.beatTimes.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text("\(editor.sequence.beatTimes.count) beat markers on this timeline").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                                HStack(spacing: Theme.Space.xs) {
                                    Text("Cut to").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                                    ForEach([1, 2, 4, 8], id: \.self) { every in
                                        Button(every == 1 ? "1 beat" : "\(every)") { editor.cutToBeat(every: every) }.buttonStyle(.kirieCompact)
                                            .help("Retime the selected main-track clips so cuts land on every \(every == 1 ? "beat" : "\(every) beats")")
                                    }
                                }
                                HStack(spacing: Theme.Space.s) {
                                    legend(tall: false, "Beat")
                                    legend(tall: true, "Bar start")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.s)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.inset))
                        }
                        PlannedNote(text: "Voiceover recording, stock music library and song-section finder.")
                    }
                    .padding(Theme.Space.m)
                }
            }
        }
    }

    private func legend(tall: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            VStack(spacing: 0) {
                if tall { Circle().fill(Theme.warning).frame(width: 5, height: 5) }
                Rectangle().fill(tall ? Theme.warning : Theme.secondary).frame(width: 1.5, height: tall ? 9 : 5)
            }
            Text(label).font(Theme.Font.small).foregroundStyle(Theme.tertiary)
        }
    }

    private func row(_ asset: MediaAsset) -> some View {
        let clip = editor.sequence.allClips.first { $0.assetID == asset.id }
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Image(systemName: "music.note").foregroundStyle(Theme.secondary)
                Text(asset.name).font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(formatDuration(asset.metadata.duration.seconds)).font(Theme.Font.mono).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: Theme.Space.xs) {
                if let bpm = asset.bpm { StatusBadge(text: String(format: "%.0f BPM", bpm), symbol: "metronome", tint: Theme.secondary) }
                if asset.rights.status == .commercialUnlicensed { StatusBadge(text: "Not exported", symbol: "music.note.list", tint: Theme.warning) }
                Spacer()
                if let clip {
                    Button("Detect beats") { editor.detectBeats(forClip: clip.id) }.buttonStyle(.kirieCompact)
                } else {
                    Button("Add at playhead") { editor.addToTimeline(asset.id) }.buttonStyle(.kirieCompact)
                }
            }
        }
        .padding(Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .onDrag { NSItemProvider(object: "\(TimelineNSView.assetDragPrefix)\(asset.id.uuidString)" as NSString) }
        .contextMenu {
            Button("Add at Playhead") { editor.addToTimeline(asset.id) }
            Button("Remove from Project") { editor.perform(.removeAsset(assetID: asset.id)) }
        }
    }
}

struct TextTab: View {
    let editor: EditorModel

    private struct Preset: Identifiable {
        let id: String
        let sample: String
        let style: TextStyle
        let animation: TextAnimation
        let position: UnitPoint2D
    }

    private let presets: [Preset] = [
        Preset(id: "Title", sample: "Title", style: TextStyle(fontName: "Helvetica Neue Bold", fontSize: 120), animation: .pop, position: UnitPoint2D(x: 0.5, y: 0.3)),
        Preset(id: "Subtitle", sample: "Subtitle", style: TextStyle(fontName: "Helvetica Neue Medium", fontSize: 64), animation: .fade, position: UnitPoint2D(x: 0.5, y: 0.42)),
        Preset(id: "Lower third", sample: "Name here", style: TextStyle(fontName: "Helvetica Neue Bold", fontSize: 54, shadow: nil,
                                                                        background: TextBackground(color: RGBAColor(r: 0.1, g: 0.09, b: 0.1, a: 0.82)), alignment: .left),
               animation: .fade, position: UnitPoint2D(x: 0.32, y: 0.8)),
        Preset(id: "Hand-lettered", sample: "hand lettered", style: TextStyle(fontName: "Marker Felt Wide", fontSize: 96, color: RGBAColor(r: 0.13, g: 0.1, b: 0.09),
                                                                               strokeColor: RGBAColor(r: 1, g: 0.98, b: 0.93), strokeWidth: 10, shadow: nil),
               animation: .typewriter, position: UnitPoint2D(x: 0.5, y: 0.2)),
        Preset(id: "Outline", sample: "OUTLINE", style: TextStyle(fontName: "Arial Rounded MT Bold", fontSize: 110, color: RGBAColor(r: 1, g: 0.86, b: 0.2),
                                                                    strokeColor: RGBAColor(r: 0.1, g: 0.08, b: 0.08), strokeWidth: 14, shadow: nil, allCaps: true),
               animation: .bounce, position: UnitPoint2D(x: 0.5, y: 0.5)),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Text")
            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(presets) { preset in
                        Button {
                            editor.addText(preset.sample, style: preset.style, animation: preset.animation, position: preset.position)
                        } label: {
                            HStack {
                                Text(preset.sample).font(.custom(preset.style.fontName, size: 17)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(preset.id).font(Theme.Font.small).foregroundStyle(Theme.secondary)
                                    Text(preset.animation.displayName).font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                                }
                            }
                            .padding(.horizontal, Theme.Space.m).frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.elevated))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add “\(preset.id)” text at the playhead")
                    }
                    Text("Text is added at the playhead for three seconds. Drag it in the preview to place it, and restyle it in the inspector.")
                        .font(Theme.Font.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    Button { importFont() } label: { Label("Import a font…", systemImage: "textformat.size") }.buttonStyle(.kirie)
                        .help("Use a TTF or OTF font in this project")
                    PlannedNote(text: "Sticker and shape library. For now, import a PNG and add it as an overlay.")
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private func importFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ttf", "otf", "ttc"].compactMap { .init(filenameExtension: $0) }
        panel.message = "Choose a TTF or OTF font. Only use fonts you are licensed to use."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try FontLibrary.importFont(url, into: editor.session)
            editor.notify(.success, "Imported \(imported.family).\(imported.license.map { " Licence: \($0.prefix(120))" } ?? " The font carries no licence text; check its terms.")")
        } catch { editor.report(error) }
    }
}

/// Project fonts: copied into the package and registered for this app only.
enum FontLibrary {
    static func folder(_ session: ProjectSession) -> URL { session.package.url.appendingPathComponent("Fonts", isDirectory: true) }

    static func registerAll(in session: ProjectSession) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(session), includingPropertiesForKeys: nil)) ?? []
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    static func importFont(_ url: URL, into session: ProjectSession) throws -> (family: String, license: String?) {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = descriptors.first else {
            throw ServiceError.invalid("“\(url.lastPathComponent)” is not a font Kirie can read.")
        }
        let font = CTFontCreateWithFontDescriptor(first, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        let license = (CTFontCopyName(font, kCTFontLicenseNameKey) ?? CTFontCopyName(font, kCTFontCopyrightNameKey)) as String?
        try FileManager.default.createDirectory(at: folder(session), withIntermediateDirectories: true)
        let destination = folder(session).appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: url, to: destination) }
        CTFontManagerRegisterFontsForURL(destination as CFURL, .process, nil)
        return (family, license)
    }
}

struct CaptionsTab: View {
    @Bindable var editor: EditorModel

    private var track: Track? { editor.sequence.tracks.first { $0.kind == .caption } }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Captions", trailing: AnyView(Menu {
                Button("Import SRT, VTT or LRC…") { editor.importCaptions() }
                Divider()
                Button("Export SRT…") { editor.exportCaptions(.srt) }.disabled(track?.clips.isEmpty != false)
                Button("Export VTT…") { editor.exportCaptions(.vtt) }.disabled(track?.clips.isEmpty != false)
                Button("Export LRC…") { editor.exportCaptions(.lrc) }.disabled(track?.clips.isEmpty != false)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("Import or export captions")))
            if let track, !track.clips.isEmpty {
                HStack {
                    Text("Animation").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                    Picker("Caption animation", selection: Binding(get: { track.clips.first?.text?.animation ?? .none }, set: { restyle(animation: $0) })) {
                        ForEach(TextAnimation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                }
                .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(track.clips) { clip in CaptionRow(editor: editor, clip: clip) }
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.m)
                }
            } else {
                EmptyState(symbol: "captions.bubble", title: "No captions",
                           message: "Import an SRT, VTT or LRC file, or select a clip with speech and choose Auto captions in the inspector. Transcription runs on this Mac.",
                           actionTitle: "Import Captions…") { editor.importCaptions() }
            }
        }
    }

    private func restyle(animation: TextAnimation) {
        guard let track else { return }
        let segments = ProjectSession.captionSegments(in: editor.sequence, trackID: track.id)
        editor.perform(.replaceCaptions(sequenceID: nil, trackID: track.id, segments: segments, style: track.clips.first?.text?.style ?? .caption, animation: animation))
    }
}

struct CaptionRow: View {
    let editor: EditorModel
    let clip: Clip
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let current = clip.range.contains(editor.playhead)
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Button { editor.player.seek(to: clip.start); editor.selection = [clip.id] } label: {
                Text(Timecode.string(clip.start, rate: editor.frameRate).dropFirst(3)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(current ? Theme.accent : Theme.tertiary).frame(width: 56, alignment: .leading)
            }
            .buttonStyle(.plain).help("Go to this caption")
            TextField("Caption", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1...3)
                .focused($focused)
                .onAppear { draft = clip.text?.string ?? "" }
                .onChange(of: clip.text?.string) { _, new in if !focused { draft = new ?? "" } }
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(current ? Theme.accentSoft : .clear))
    }

    private func commit() {
        guard var text = clip.text, draft != text.string, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text.string = draft
        // Word timing no longer matches edited text.
        text.words = []
        editor.perform(.setText(clipID: clip.id, text: text))
    }
}

struct TransitionsTab: View {
    let editor: EditorModel

    private var targets: [Clip] { editor.selectedClips.filter(\.isVisual) }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Transitions")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(targets.isEmpty ? "Select a clip, then choose how it comes in." : "Applies to the start of the \(targets.count == 1 ? "selected clip" : "\(targets.count) selected clips").")
                        .font(Theme.Font.label).foregroundStyle(targets.isEmpty ? Theme.warning : Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    group("Standard", TransitionType.allCases.filter { !$0.isComic })
                    group("Comic", TransitionType.allCases.filter(\.isComic))
                    Button("Remove transition") { editor.perform(targets.map { .setTransition(clipID: $0.id, transition: nil) }, label: "Remove transition") }
                        .buttonStyle(.kirie).disabled(targets.allSatisfy { $0.transitionIn == nil })
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private func group(_ title: String, _ types: [TransitionType]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title.uppercased()).font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.tertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Theme.Space.xs)], spacing: Theme.Space.xs) {
                ForEach(types, id: \.self) { type in
                    let active = !targets.isEmpty && targets.allSatisfy { $0.transitionIn?.type == type }
                    Button {
                        editor.perform(targets.map { .setTransition(clipID: $0.id, transition: Transition(type: type, duration: $0.transitionIn?.duration ?? RationalTime(seconds: 0.45),
                                                                                                           direction: $0.transitionIn?.direction ?? .left)) },
                                       label: "Add \(type.displayName.lowercased()) transition")
                    } label: {
                        Text(type.displayName).font(Theme.Font.label).foregroundStyle(active ? Theme.accent : Theme.text)
                            .frame(maxWidth: .infinity).frame(height: Theme.Size.control)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(active ? Theme.accentSoft : Theme.elevated))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(active ? Theme.accent : Theme.border))
                    }
                    .buttonStyle(.plain).disabled(targets.isEmpty)
                }
            }
        }
    }
}

struct EffectsTab: View {
    let editor: EditorModel

    private var targets: [Clip] { editor.selectedClips.filter { $0.kind == .video || $0.kind == .image } }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Effects")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(targets.isEmpty ? "Select a video clip or picture, then add a look or an effect." : "Adds to the \(targets.count == 1 ? "selected clip" : "\(targets.count) selected clips"). Adjust intensity in the inspector.")
                        .font(Theme.Font.label).foregroundStyle(targets.isEmpty ? Theme.warning : Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    group("Looks", FilterKind.allCases.filter(\.isLook))
                    group("Effects", FilterKind.allCases.filter { !$0.isLook })
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private func group(_ title: String, _ kinds: [FilterKind]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title.uppercased()).font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.tertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Theme.Space.xs)], spacing: Theme.Space.xs) {
                ForEach(kinds, id: \.self) { kind in
                    Button {
                        editor.perform(targets.map { clip in
                            .setLook(clipID: clip.id, color: clip.color, filters: clip.filters + [AppliedFilter(kind: kind)], blendMode: clip.blendMode, mask: clip.mask, chromaKey: clip.chromaKey)
                        }, label: "Add \(kind.displayName.lowercased())")
                    } label: {
                        Text(kind.displayName).font(Theme.Font.label).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity).frame(height: Theme.Size.control)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.elevated))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain).disabled(targets.isEmpty)
                }
            }
        }
    }
}
