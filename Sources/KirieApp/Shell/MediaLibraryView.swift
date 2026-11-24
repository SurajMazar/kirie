import AppKit
import AVKit
import ProjectDomain
import SwiftUI

/// Full-window asset management for the open project.
struct MediaLibraryView: View {
    @Bindable var editor: EditorModel
    @State private var search = ""
    @State private var filter = Filter.all
    @AppStorage("library.grid") private var grid = true

    enum Filter: String, CaseIterable, Identifiable {
        case all, video, pictures, audio, favourites, unused, missing
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private var assets: [MediaAsset] {
        editor.project.assets.filter { asset in
            let matches: Bool = switch filter {
            case .all: true
            case .video: asset.kind == .video
            case .pictures: asset.kind == .image
            case .audio: asset.kind == .audio
            case .favourites: asset.favourite
            case .unused: !editor.project.isAssetInUse(asset.id)
            case .missing: editor.missingMedia.contains { $0.id == asset.id }
            }
            return matches && (search.isEmpty || asset.name.localizedCaseInsensitiveContains(search) || asset.keywords.contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var selected: MediaAsset? { editor.project.asset(editor.selectedAssetID) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider1()
                if editor.project.assets.isEmpty {
                    EmptyState(symbol: "photo.on.rectangle.angled", title: "No media in this project",
                               message: "Import video, audio and pictures. Kirie reads them where they are; your originals are never changed.",
                               actionTitle: "Import Media…") { editor.chooseFilesToImport() }
                } else if assets.isEmpty {
                    EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches", message: "Try another filter or clear the search.")
                } else if grid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                            ForEach(assets) { asset in gridCell(asset) }
                        }
                        .padding(Theme.Space.l)
                    }
                } else {
                    ScrollView { LazyVStack(spacing: 0) { ForEach(assets) { asset in listRow(asset) } } }
                }
            }
            Divider1(vertical: true)
            detail.frame(width: 300)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Media Library").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
            Text("\(editor.project.assets.count)").font(Theme.Font.label).foregroundStyle(Theme.tertiary)
            Spacer()
            Picker("Filter", selection: $filter) { ForEach(Filter.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 120)
                .help("Smart filters: by type, favourites, unused or missing")
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                TextField("Name or keyword", text: $search).textFieldStyle(.plain).font(Theme.Font.body).frame(width: 150)
            }
            .padding(.horizontal, Theme.Space.s).frame(height: Theme.Size.control)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.inset))
            IconButton(symbol: "square.grid.2x2", label: "Grid view", active: grid) { grid = true }
            IconButton(symbol: "list.bullet", label: "List view", active: !grid) { grid = false }
            Button { editor.chooseFilesToImport() } label: { Label("Import", systemImage: "plus") }.buttonStyle(.kiriePrimary)
        }
        .padding(.horizontal, Theme.Space.l).frame(height: 56)
    }

    private func badges(_ asset: MediaAsset) -> some View {
        HStack(spacing: 3) {
            if asset.favourite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.warning) }
            if editor.missingMedia.contains(where: { $0.id == asset.id }) { StatusBadge(text: "Missing", symbol: "exclamationmark.triangle.fill", tint: Theme.warning) }
            else if asset.reference.relativePath != nil { StatusBadge(text: "In project", tint: Theme.tertiary) }
            if !editor.project.isAssetInUse(asset.id) { StatusBadge(text: "Unused", tint: Theme.tertiary) }
        }
    }

    private func gridCell(_ asset: MediaAsset) -> some View {
        let isSelected = editor.selectedAssetID == asset.id
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            AssetThumbnail(editor: editor, asset: asset).frame(height: 110).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 2 : 1))
            Text(asset.name).font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            HStack(spacing: Theme.Space.xs) {
                Text(asset.kind == .image ? "\(asset.metadata.displayWidth)×\(asset.metadata.displayHeight)" : formatDuration(asset.metadata.duration.seconds))
                    .font(Theme.Font.small).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                badges(asset)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editor.addToTimeline(asset.id) }
        .onTapGesture { editor.selectedAssetID = asset.id }
        .contextMenu { menu(asset) }
        .accessibilityLabel("\(asset.name), \(asset.kind.rawValue)")
    }

    private func listRow(_ asset: MediaAsset) -> some View {
        let isSelected = editor.selectedAssetID == asset.id
        return HStack(spacing: Theme.Space.m) {
            AssetThumbnail(editor: editor, asset: asset).frame(width: 52, height: 36).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
            Text(asset.name).font(Theme.Font.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).frame(minWidth: 180, alignment: .leading)
            badges(asset)
            Spacer()
            Text(asset.kind.rawValue.capitalized).font(Theme.Font.label).foregroundStyle(Theme.secondary).frame(width: 60, alignment: .leading)
            Text(asset.kind == .audio ? "" : "\(asset.metadata.displayWidth)×\(asset.metadata.displayHeight)").font(Theme.Font.mono).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing)
            Text(asset.kind == .image ? "" : formatDuration(asset.metadata.duration.seconds)).font(Theme.Font.mono).foregroundStyle(Theme.secondary).frame(width: 50, alignment: .trailing)
            Text(formatBytes(asset.reference.fileSize)).font(Theme.Font.mono).foregroundStyle(Theme.tertiary).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.l).frame(height: 46)
        .background(isSelected ? Theme.accentSoft : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editor.addToTimeline(asset.id) }
        .onTapGesture { editor.selectedAssetID = asset.id }
        .contextMenu { menu(asset) }
        .overlay(alignment: .bottom) { Divider1() }
    }

    @ViewBuilder private func menu(_ asset: MediaAsset) -> some View {
        Button("Add to Timeline") { editor.addToTimeline(asset.id) }
        if asset.kind != .audio { Button("Add as Overlay at Playhead") { editor.addOverlay(asset.id) } }
        Button(asset.favourite ? "Remove Favourite" : "Favourite") {
            editor.perform(.updateAssetInfo(assetID: asset.id, name: nil, rights: nil, favourite: !asset.favourite, rating: nil, keywords: nil, bpm: nil), reload: false)
        }
        Divider()
        Button("Show in Finder") { if let url = editor.session.resolver.url(for: asset) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        Button("Relink…") { editor.relink(asset) }
        Button("Remove from Project") { editor.perform(.removeAsset(assetID: asset.id)) }
    }

    @ViewBuilder private var detail: some View {
        if let asset = selected {
            AssetDetail(editor: editor, asset: asset)
        } else {
            EmptyState(symbol: "info.circle", title: "No item selected", message: "Select a media item to see its details, rate it, tag it and set its rights.").background(Theme.panel)
        }
    }
}

struct AssetDetail: View {
    let editor: EditorModel
    let asset: MediaAsset
    @State private var keywords = ""
    @State private var songTitle = ""
    @State private var songArtist = ""

    private var missing: Bool { editor.missingMedia.contains { $0.id == asset.id } }

    private func update(rights: RightsInfo? = nil, favourite: Bool? = nil, rating: Int? = nil, keywords: [String]? = nil) {
        editor.perform(.updateAssetInfo(assetID: asset.id, name: nil, rights: rights, favourite: favourite, rating: rating, keywords: keywords, bpm: nil), reload: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if asset.kind != .image, !missing, let url = editor.session.resolver.url(for: asset) {
                        AssetPlayer(url: url).frame(height: asset.kind == .audio ? 60 : 190)
                    } else {
                        AssetThumbnail(editor: editor, asset: asset).frame(height: 190)
                    }
                }
                .background(Theme.inset)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(asset.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Button { update(rating: asset.rating == star ? 0 : star) } label: {
                                Image(systemName: star <= asset.rating ? "star.fill" : "star").font(.system(size: 12)).foregroundStyle(star <= asset.rating ? Theme.warning : Theme.tertiary)
                            }
                            .buttonStyle(.plain).accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                        }
                        Spacer()
                        Toggle("Favourite", isOn: Binding(get: { asset.favourite }, set: { update(favourite: $0) })).toggleStyle(.checkbox).font(Theme.Font.label)
                    }
                    if missing {
                        HStack {
                            Label("The file is missing", systemImage: "exclamationmark.triangle.fill").font(Theme.Font.label).foregroundStyle(Theme.warning)
                            Spacer()
                            Button("Relink…") { editor.relink(asset) }.buttonStyle(.kirieCompact)
                        }
                    }
                    Button { editor.addToTimeline(asset.id) } label: { Label("Add to timeline", systemImage: "plus.rectangle.on.rectangle") }.buttonStyle(.kirie)
                }
                .padding(Theme.Space.m)
                Divider1()
                InspectorSection("Details") {
                    line("Type", asset.kind.rawValue.capitalized)
                    if asset.metadata.hasVideo { line("Size", "\(asset.metadata.displayWidth) × \(asset.metadata.displayHeight)") }
                    if asset.kind != .image { line("Length", String(format: "%.2f s", asset.metadata.duration.seconds)) }
                    if asset.kind == .video {
                        line("Frame rate", String(format: "%.2f fps", asset.metadata.frameRate))
                        line("Codec", asset.metadata.videoCodec ?? "unknown")
                        line("Colour", [asset.metadata.colorPrimaries, asset.metadata.transferFunction].compactMap { $0 }.joined(separator: " / ").isEmpty ? "untagged" :
                            [asset.metadata.colorPrimaries, asset.metadata.transferFunction].compactMap { $0 }.joined(separator: " / "))
                        if asset.metadata.isHDR { line("HDR", "Yes. Kirie previews and exports it as SDR.") }
                        if asset.metadata.rotationDegrees != 0 { line("Rotation", "\(asset.metadata.rotationDegrees)°") }
                    }
                    if asset.metadata.hasAudio { line("Audio", "\(asset.metadata.audioChannels) ch · \(Int(asset.metadata.sampleRate)) Hz · \(asset.metadata.audioCodec ?? "")") }
                    if let bpm = asset.bpm { line("Tempo", String(format: "%.0f BPM", bpm)) }
                    line("File size", formatBytes(asset.reference.fileSize))
                    line("Imported", asset.importedAt.formatted(date: .abbreviated, time: .shortened))
                    line("Location", asset.reference.relativePath.map { "In project: \($0)" } ?? asset.reference.absolutePath)
                    line("Source", "Original file. Proxies are planned for Phase 2.")
                }
                InspectorSection("Keywords") {
                    KirieField(placeholder: "Comma-separated keywords", text: $keywords) {
                        let list = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if list != asset.keywords { update(keywords: list) }
                    }
                }
                if asset.metadata.hasAudio {
                    InspectorSection("Rights") {
                        Picker("Rights", selection: Binding(get: { asset.rights.status }, set: { status in
                            var rights = asset.rights; rights.status = status
                            update(rights: rights)
                        })) {
                            ForEach(RightsStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        if asset.rights.status == .commercialUnlicensed {
                            KirieField(placeholder: "Song title", text: $songTitle) { commitSong() }
                            KirieField(placeholder: "Artist", text: $songArtist) { commitSong() }
                            Text("Commercial music plays in the preview but is never written into an export. Kirie exports silently with a note naming the song to add in the app.")
                                .font(Theme.Font.small).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .background(Theme.panel)
        .onAppear(perform: load)
        .onChange(of: asset.id) { _, _ in load() }
    }

    private func load() {
        keywords = asset.keywords.joined(separator: ", ")
        songTitle = asset.rights.title ?? ""
        songArtist = asset.rights.artist ?? ""
    }

    private func commitSong() {
        var rights = asset.rights
        rights.title = songTitle.isEmpty ? nil : songTitle
        rights.artist = songArtist.isEmpty ? nil : songArtist
        if rights != asset.rights { update(rights: rights) }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(Theme.Font.label).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Plays one source file with the standard macOS controls.
struct AssetPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }
}
