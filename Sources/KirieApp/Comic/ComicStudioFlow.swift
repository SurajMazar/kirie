import AppKit
import AVFoundation
import ComicStudio
import KirieServices
import MediaServices
import ProjectDomain
import SwiftUI

// MARK: Montage

struct MontageBuilderSection: View {
    @Bindable var editor: EditorModel
    let openEditor: () -> Void
    @State private var plan = MontagePlan()
    @State private var each = 2.5
    @State private var every = 2

    private var pictures: [MediaAsset] { editor.project.assets.filter { $0.kind == .image } }
    private var songs: [MediaAsset] { editor.project.assets.filter { $0.kind == .audio } }

    var body: some View {
        ComicPage(title: "Montage", subtitle: "Stills on a time grid: verses dissolve, choruses cut hard, the peak frame holds, the last frame lingers.") {
            Button {
                commit()
                do {
                    let sequence = try editor.session.buildMontage()
                    editor.syncFromSession()
                    editor.notify(.success, String(format: "Built the montage: %d frames, %.1f s", sequence.mainTrack?.clips.count ?? 0, sequence.duration.seconds))
                    openEditor()
                } catch { editor.syncFromSession(reload: false); editor.report(error) }
            } label: { Label("Build Montage", systemImage: "photo.stack") }
            .buttonStyle(.kiriePrimary).disabled(plan.frames.isEmpty)
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Menu {
                        Button("All project pictures") { add(pictures.filter { asset in !plan.frames.contains { $0.assetID == asset.id } }) }
                        Divider()
                        ForEach(pictures) { asset in Button(asset.name) { add([asset]) } }
                    } label: { Label("Add pictures", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(pictures.isEmpty)
                    Button("Import pictures…") { editor.chooseFilesToImport() }.buttonStyle(.kirieCompact)
                    Divider1(vertical: true).frame(height: 14)
                    Text("Spread").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                    TextField("", value: $each, format: .number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 46)
                    Button("s each") { spread() }.buttonStyle(.kirieCompact).disabled(plan.frames.isEmpty).help("Give every frame the same length")
                    Button("Snap to beats, every \(every)") { snapToBeats() }.buttonStyle(.kirieCompact).disabled(plan.frames.isEmpty || plan.audioAssetID == nil)
                        .help("Detect the song's beats and start each frame on every \(every)th beat")
                    Stepper("", value: $every, in: 1...16).labelsHidden().controlSize(.small)
                    Button("Import times.json…") { importTimes() }.buttonStyle(.kirieCompact).help("A list of {\"line\", \"start\", \"end\"} entries; each line names a picture")
                    Spacer()
                    Text("Song").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                    Picker("Song", selection: Binding(get: { plan.audioAssetID }, set: { plan.audioAssetID = $0; commit() })) {
                        Text("None").tag(UUID?.none)
                        ForEach(songs) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 160)
                }
                .padding(.horizontal, Theme.Space.m).frame(height: 40).background(Theme.panel)
                Divider1()
                if plan.frames.isEmpty {
                    EmptyState(symbol: "photo.stack", title: "No frames yet",
                               message: pictures.isEmpty ? "Import the pictures for this montage, then add them here." : "Add pictures from the project, then set when each one appears.",
                               actionTitle: pictures.isEmpty ? "Import Pictures…" : "Add All Pictures") { pictures.isEmpty ? editor.chooseFilesToImport() : add(pictures) }
                } else {
                    ScrollView {
                        LazyVStack(spacing: Theme.Space.xs) {
                            ForEach(Array(plan.frames.enumerated()), id: \.element.id) { index, frame in row(index, frame) }
                        }
                        .padding(Theme.Space.m)
                    }
                }
            }
        }
        .onAppear { plan = editor.project.comic?.montage ?? MontagePlan() }
    }

    private func row(_ index: Int, _ frame: MontageFrame) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text("\(index + 1)").font(Theme.Font.mono).foregroundStyle(Theme.tertiary).frame(width: 20)
            if let asset = editor.project.asset(frame.assetID) {
                AssetThumbnail(editor: editor, asset: asset).frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 3))
                Text(asset.name).font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1).frame(width: 150, alignment: .leading)
            }
            timeField("Start", frame.start) { plan.frames[index].start = $0; commit() }
            timeField("End", frame.end) { plan.frames[index].end = $0; commit() }
            Picker("Section", selection: Binding(get: { frame.section }, set: { section in
                plan.frames[index].section = section
                plan.frames[index].transition = ComicBuilder.defaultTransition(for: section, rate: editor.frameRate)
                commit()
            })) {
                Text("Verse (dissolve)").tag(ProjectDomain.MontageSection.verse)
                Text("Chorus (hard cut)").tag(ProjectDomain.MontageSection.chorus)
                Text("Peak (hold)").tag(ProjectDomain.MontageSection.peak)
                Text("Final (linger)").tag(ProjectDomain.MontageSection.final)
            }
            .labelsHidden().controlSize(.small).frame(width: 150)
            Spacer()
            IconButton(symbol: "chevron.up", label: "Move frame \(index + 1) earlier", size: 20) { swap(index, index - 1) }.disabled(index == 0)
            IconButton(symbol: "chevron.down", label: "Move frame \(index + 1) later", size: 20) { swap(index, index + 1) }.disabled(index == plan.frames.count - 1)
            IconButton(symbol: "xmark", label: "Remove frame \(index + 1)", size: 20) { plan.frames.remove(at: index); commit() }
        }
        .padding(.horizontal, Theme.Space.s).frame(height: 64)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
    }

    private func timeField(_ label: String, _ time: RationalTime, set: @escaping (RationalTime) -> Void) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Text(label).font(Theme.Font.small).foregroundStyle(Theme.tertiary)
            TextField("", value: Binding(get: { time.seconds }, set: { set(RationalTime(seconds: max(0, $0))) }), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 58).font(Theme.Font.mono)
        }
    }

    private func commit() {
        guard editor.project.comic != nil, plan != editor.project.comic?.montage else { return }
        // Only valid plans are stored; an invalid row is reported and kept on screen for fixing.
        editor.perform(.comic(command: .setMontage(plan: plan)), reload: false)
    }

    private func add(_ assets: [MediaAsset]) {
        var cursor = plan.frames.map(\.end).max() ?? .zero
        for asset in assets {
            let end = cursor + RationalTime(seconds: each)
            plan.frames.append(MontageFrame(assetID: asset.id, start: cursor, end: end, transition: plan.frames.isEmpty ? nil : ComicBuilder.defaultTransition(for: .verse, rate: editor.frameRate)))
            cursor = end
        }
        commit()
    }

    private func spread() {
        var cursor = RationalTime.zero
        for index in plan.frames.indices {
            plan.frames[index].start = cursor
            cursor += RationalTime(seconds: max(0.2, each))
            plan.frames[index].end = cursor
        }
        commit()
    }

    private func swap(_ a: Int, _ b: Int) {
        // Pictures trade places; the time grid stays where it is.
        let first = plan.frames[a].assetID
        plan.frames[a].assetID = plan.frames[b].assetID
        plan.frames[b].assetID = first
        commit()
    }

    private func snapToBeats() {
        guard let song = plan.audioAssetID else { return }
        Task {
            do {
                let analysis = try await editor.session.analyseBeats(assetID: song)
                let grid = stride(from: 0, to: analysis.beats.count, by: every).map { analysis.beats[$0] }
                guard grid.count > plan.frames.count else {
                    editor.notify(.warning, "The song has \(grid.count) usable beats at this spacing, but there are \(plan.frames.count) frames. Use a smaller interval.")
                    return
                }
                for index in plan.frames.indices {
                    plan.frames[index].start = index == 0 ? .zero : RationalTime(seconds: grid[index])
                    plan.frames[index].end = RationalTime(seconds: grid[index + 1])
                }
                commit()
                editor.notify(.success, String(format: "Frames placed on the beat (%.0f BPM)", analysis.bpm))
            } catch { editor.report(error) }
        }
    }

    private func importTimes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            plan.frames = try ComicBuilder.montageFrames(fromTimesJSON: data, assets: editor.project.assets)
            commit()
            editor.notify(.success, "Imported \(plan.frames.count) timed frames")
        } catch { editor.report(error) }
    }
}

// MARK: Lyric Studio

/// Plays the song for tap-to-time, independently of the timeline player.
@MainActor
@Observable
final class SongPlayer {
    let player = AVPlayer()
    private(set) var time = 0.0
    private(set) var duration = 0.0
    private(set) var playing = false
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var loaded: URL?

    func load(_ url: URL?) {
        guard url != loaded else { return }
        loaded = url
        player.pause()
        playing = false
        time = 0
        if let observer { player.removeTimeObserver(observer) }
        guard let url else { player.replaceCurrentItem(with: nil); duration = 0; return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                self?.time = now.seconds
                if self?.player.rate == 0 { self?.playing = false }
            }
        }
        Task {
            let length = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            self.duration = length.isFinite ? length : 0
        }
    }

    func toggle() {
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    func seek(_ seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() { player.pause(); playing = false }
}

struct LyricSection: View {
    @Bindable var editor: EditorModel
    let openEditor: () -> Void
    @State private var edit = LyricEdit()
    @State private var selected: UUID?
    @State private var song = SongPlayer()
    @State private var tapMode = TapMode.off
    @State private var tapIndex = 0
    @State private var keyMonitor: Any?

    enum TapMode: String, CaseIterable, Identifiable {
        case off, lines, words
        var id: String { rawValue }
    }

    private var songs: [MediaAsset] { editor.project.assets.filter { $0.metadata.hasAudio } }
    private var pictures: [MediaAsset] { editor.project.assets.filter { $0.kind == .image } }
    private var selectedIndex: Int? { edit.lines.firstIndex { $0.id == selected } }

    var body: some View {
        ComicPage(title: "Lyric Studio", subtitle: "One full-screen picture per line, with the words arriving in time inside the picture's empty area.") {
            Button {
                commit()
                do {
                    let sequence = try editor.session.buildLyricEdit()
                    editor.syncFromSession()
                    song.stop()
                    if let index = selectedIndex { editor.player.seek(to: edit.lines[index].start) }
                    editor.notify(.success, String(format: "Built the lyric edit: %d lines, %.1f s", edit.lines.count, sequence.duration.seconds))
                    openEditor()
                } catch { editor.syncFromSession(reload: false); editor.report(error) }
            } label: { Label("Build Lyric Edit", systemImage: "music.mic") }
            .buttonStyle(.kiriePrimary).disabled(edit.lines.isEmpty)
        } content: {
            VStack(spacing: 0) {
                transport
                Divider1()
                HStack(spacing: 0) {
                    lineList
                    Divider1(vertical: true)
                    detail.frame(width: 320)
                }
            }
        }
        .onAppear {
            edit = editor.project.comic?.lyricEdit ?? LyricEdit()
            loadSong()
            installKeys()
        }
        .onDisappear {
            song.stop()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: Song transport and tap-to-time

    private var transport: some View {
        HStack(spacing: Theme.Space.s) {
            Picker("Song", selection: Binding(get: { edit.audioAssetID }, set: { edit.audioAssetID = $0; commit(); loadSong() })) {
                Text("No song").tag(UUID?.none)
                ForEach(songs) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden().controlSize(.small).frame(width: 170)
            if let asset = editor.project.asset(edit.audioAssetID), asset.rights.status == .commercialUnlicensed {
                StatusBadge(text: "Timing only: not exported", symbol: "music.note.list", tint: Theme.warning)
                    .help("This song is marked commercial. Kirie times the lettering to it, exports silently and writes a song note.")
            }
            IconButton(symbol: song.playing ? "pause.fill" : "play.fill", label: song.playing ? "Pause song" : "Play song") { song.toggle() }.disabled(edit.audioAssetID == nil)
            Text(String(format: "%05.2f", song.time)).font(Theme.Font.timecode).foregroundStyle(Theme.text).frame(width: 58, alignment: .leading)
            Slider(value: Binding(get: { song.time }, set: { song.seek($0) }), in: 0...max(0.1, song.duration)).controlSize(.mini).disabled(edit.audioAssetID == nil)
                .accessibilityLabel("Song position")
            Divider1(vertical: true).frame(height: 14)
            Text("Tap with T").font(Theme.Font.label).foregroundStyle(Theme.secondary)
            Picker("Tap mode", selection: $tapMode) {
                Text("Off").tag(TapMode.off)
                Text("Lines").tag(TapMode.lines)
                Text("Words").tag(TapMode.words)
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 170)
            .onChange(of: tapMode) { _, mode in
                tapIndex = mode == .lines ? (selectedIndex ?? 0) : 0
            }
            .help("Lines: each tap starts the next line at the song's current time. Words: each tap stamps the next word of the selected line.")
            if tapMode != .off {
                StatusBadge(text: tapMode == .lines ? "Next: line \(min(tapIndex + 1, max(1, edit.lines.count)))" : "Next: word \(tapIndex + 1)", symbol: "hand.tap", tint: Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Space.m).frame(height: 40).background(Theme.panel)
    }

    private func loadSong() {
        song.load(editor.project.asset(edit.audioAssetID).flatMap { editor.session.resolver.url(for: $0) })
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard tapMode != .off, !(NSApp.keyWindow?.firstResponder is NSText), event.charactersIgnoringModifiers?.lowercased() == "t",
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            tap()
            return nil
        }
    }

    private func tap() {
        let now = RationalTime(seconds: song.time, timescale: 1000)
        switch tapMode {
        case .off:
            return
        case .lines:
            guard tapIndex < edit.lines.count else { return }
            let length = edit.lines[tapIndex].end - edit.lines[tapIndex].start
            edit.lines[tapIndex].start = now
            edit.lines[tapIndex].end = now + RationalTime.max(length, RationalTime(1, 2))
            // The previous line ends where this one begins.
            if tapIndex > 0 { edit.lines[tapIndex - 1].end = now }
            for shot in edit.lines[tapIndex].shots.indices.prefix(1) { edit.lines[tapIndex].shots[shot].at = now }
            selected = edit.lines[tapIndex].id
            tapIndex += 1
        case .words:
            guard let index = selectedIndex else { return }
            let count = LyricMarkup.parse(edit.lines[index].text).wordCount
            guard tapIndex < count else { return }
            var times = edit.lines[index].wordTimes
            while times.count < count { times.append(nil) }
            times[tapIndex] = now
            edit.lines[index].wordTimes = times
            tapIndex += 1
        }
        commit()
    }

    // MARK: Lines

    private var lineList: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Button { addLine() } label: { Label("Add line", systemImage: "plus") }.buttonStyle(.kirieCompact)
                Button("Import LRC…") { importLRC() }.buttonStyle(.kirieCompact).help("Timed lyrics you wrote or own. Each line becomes a lyric line.")
                Spacer()
                Text("*word* = big · / = new row").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, Theme.Space.m).frame(height: 34)
            Divider1()
            if edit.lines.isEmpty {
                EmptyState(symbol: "music.mic", title: "No lyric lines", message: "Add lines and type your own words, or import an LRC file. Then give each line a picture and tap in the timing while the song plays.",
                           actionTitle: "Add a Line", action: addLine)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.xs) {
                        ForEach(Array(edit.lines.enumerated()), id: \.element.id) { index, line in lineRow(index, line) }
                    }
                    .padding(Theme.Space.m)
                }
            }
        }
    }

    private func lineRow(_ index: Int, _ line: LyricLine) -> some View {
        let isSelected = selected == line.id
        let playing = song.time >= line.start.seconds && song.time < line.end.seconds
        return HStack(spacing: Theme.Space.s) {
            Text("\(index + 1)").font(Theme.Font.mono).foregroundStyle(playing ? Theme.accent : Theme.tertiary).frame(width: 20)
            if let asset = editor.project.asset(line.shots.first?.assetID) {
                AssetThumbnail(editor: editor, asset: asset).frame(width: 30, height: 44).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.warning, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 30, height: 44)
                    .overlay(Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(Theme.warning)).help("This line has no picture yet")
            }
            TextField("Lyric line", text: Binding(get: { line.text }, set: { edit.lines[index].text = $0 }))
                .textFieldStyle(.plain).font(Theme.Font.body).onSubmit(commit)
            Text(String(format: "%.2f–%.2f", line.start.seconds, line.end.seconds)).font(Theme.Font.mono).foregroundStyle(Theme.secondary)
            Text(line.style.displayName).font(Theme.Font.small).foregroundStyle(Theme.tertiary).frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.s).frame(height: 54)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(isSelected ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(isSelected ? Theme.accent : Theme.border))
        .contentShape(Rectangle())
        .onTapGesture {
            commit()
            selected = line.id
            tapIndex = tapMode == .lines ? index : 0
            song.seek(line.start.seconds)
        }
    }

    @ViewBuilder private var detail: some View {
        if let index = selectedIndex {
            let line = edit.lines[index]
            let rows = LyricMarkup.parse(line.text)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    // The line's picture with its lettering laid out roughly where it will appear.
                    ZStack(alignment: .top) {
                        Theme.inset
                        if let asset = editor.project.asset(line.shots.first?.assetID), let image = editor.cache.thumbnail(for: asset, session: editor.session) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        }
                        VStack(alignment: line.style == .verse || line.style == .chorus ? .center : .leading, spacing: 2) {
                            ForEach(Array(rows.rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 4) {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, token in
                                        Text(line.style == .chorus || line.style == .block ? token.text.uppercased() : token.text)
                                            .font(.system(size: token.emphasised ? 19 : 13, weight: .bold, design: .rounded))
                                            .foregroundStyle(token.emphasised ? Theme.danger : Color.black.opacity(0.85))
                                    }
                                }
                            }
                        }
                        .padding(6).background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.75))).padding(.top, 22)
                    }
                    .aspectRatio(9.0 / 16.0, contentMode: .fit).frame(maxHeight: 250).clipped().frame(maxWidth: .infinity)
                    .overlay(Rectangle().strokeBorder(Theme.border))
                    .accessibilityLabel("Preview of line \(index + 1)")

                    ComicCard(title: "Picture") {
                        Picker("Picture", selection: Binding(get: { line.shots.first?.assetID }, set: { assetID in
                            if let assetID {
                                if edit.lines[index].shots.isEmpty { edit.lines[index].shots = [LyricShot(at: line.start, assetID: assetID)] } else { edit.lines[index].shots[0].assetID = assetID }
                            } else {
                                edit.lines[index].shots = []
                            }
                            commit()
                        })) {
                            Text("Keep the previous picture").tag(UUID?.none)
                            ForEach(pictures) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden().controlSize(.small)
                        if !line.shots.isEmpty {
                            PropertyRow(label: "Cut in") {
                                Picker("Cut", selection: Binding(get: { line.shots[0].cut }, set: { edit.lines[index].shots[0].cut = $0; commit() })) {
                                    ForEach(ShotCut.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                                }
                                .labelsHidden().controlSize(.small)
                            }
                            HStack {
                                Button("Add a close-up mid-line") {
                                    let middle = line.start + (line.end - line.start).scaled(by: 0.5)
                                    edit.lines[index].shots.append(LyricShot(at: middle, assetID: line.shots[0].assetID, zoom: 1.6, focus: UnitPoint2D(x: 0.5, y: 0.62), cut: .hard))
                                    commit()
                                }
                                .buttonStyle(.kirieCompact)
                                if line.shots.count > 1 {
                                    Button("Remove close-ups (\(line.shots.count - 1))") { edit.lines[index].shots = Array(line.shots.prefix(1)); commit() }.buttonStyle(.kirieCompact)
                                }
                            }
                        }
                    }
                    ComicCard(title: "Lettering") {
                        Picker("Style", selection: Binding(get: { line.style }, set: { edit.lines[index].style = $0; commit() })) {
                            ForEach(LyricStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                        Text(styleNote(line.style)).font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                    }
                    ComicCard(title: "Timing") {
                        HStack {
                            Text("Start").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                            TextField("", value: Binding(get: { line.start.seconds }, set: { edit.lines[index].start = RationalTime(seconds: max(0, $0)); commit() }), format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 62)
                            Text("End").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                            TextField("", value: Binding(get: { line.end.seconds }, set: { edit.lines[index].end = RationalTime(seconds: max(0, $0)); commit() }), format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 62)
                        }
                        PropertySlider(label: "Hold", value: Binding(get: { line.hold }, set: { edit.lines[index].hold = $0 }), range: 0.25...0.6, format: "%.2f", unit: "s") { if !$0 { commit() } }
                        let times = WordTiming.distribute(wordCount: rows.wordCount, start: line.start, end: line.end, hold: line.hold, overrides: line.wordTimes)
                        if !times.isEmpty {
                            Text(zip(rows.words, times).map { String(format: "%@ %.2f", $0.text, $1.seconds) }.joined(separator: "  ·  "))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if line.wordTimes.contains(where: { $0 != nil }) {
                            Button("Clear tapped word times") { edit.lines[index].wordTimes = []; commit() }.buttonStyle(.kirieCompact)
                        } else {
                            Text("Words are spread evenly across the line, then the whole line holds. Use Tap › Words to place them by ear.")
                                .font(Theme.Font.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(role: .destructive) { edit.lines.remove(at: index); selected = nil; commit() } label: { Label("Delete line", systemImage: "trash") }.buttonStyle(.kirie)
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.panel)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ComicCard(title: "Look") {
                    Picker("Artwork", selection: Binding(get: { edit.fit }, set: { edit.fit = $0; commit() })) {
                        Text("Fill 9:16 (crop the sides)").tag(FitMode.cover)
                        Text("Show the whole picture").tag(FitMode.contain)
                    }
                    .labelsHidden().controlSize(.small)
                    Toggle("Hand-lettered jitter on the words", isOn: Binding(get: { edit.letterJitter }, set: { edit.letterJitter = $0; commit() })).toggleStyle(.checkbox).font(Theme.Font.label)
                    Toggle("Flash on chorus lines", isOn: Binding(get: { edit.chorusFlash }, set: { edit.chorusFlash = $0; commit() })).toggleStyle(.checkbox).font(Theme.Font.label)
                    Toggle("Slow punch-in on each picture", isOn: Binding(get: { edit.punchIn }, set: { edit.punchIn = $0; commit() })).toggleStyle(.checkbox).font(Theme.Font.label)
                    Toggle("Crayon stripe behind the words", isOn: Binding(get: { edit.stripe != nil }, set: { edit.stripe = $0 ? RGBAColor(r: 1, g: 0.9, b: 0.45) : nil; commit() }))
                        .toggleStyle(.checkbox).font(Theme.Font.label)
                    Text("The picture itself never wobbles; only the lettering moves.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                }
                Text("Select a line to give it a picture, a style and its timing.").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(Theme.Space.m).background(Theme.panel)
        }
    }

    private func styleNote(_ style: LyricStyle) -> String {
        switch style {
        case .verse: "Hand-lettered rows that type on."
        case .stack: "Zig-zag rows whose words rise into place."
        case .chorus: "Bold capitals that slam in."
        case .block: "A left-aligned stack with one big word."
        }
    }

    private func commit() {
        guard editor.project.comic != nil, edit != editor.project.comic?.lyricEdit else { return }
        editor.perform(.comic(command: .setLyricEdit(edit: edit)), reload: false)
    }

    private func addLine() {
        let start = edit.lines.map(\.end).max() ?? RationalTime(seconds: max(0, song.time))
        let line = LyricLine(start: start, end: start + RationalTime(seconds: 3), text: "your words here",
                             shots: pictures.first.map { [LyricShot(at: start, assetID: $0.id)] } ?? [])
        edit.lines.append(line)
        selected = line.id
        commit()
    }

    private func importLRC() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["lrc", "srt", "vtt"].compactMap { .init(filenameExtension: $0) }
        panel.message = "Choose timed lyrics that you wrote or have the right to use"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let format = SubtitleFormat(fileExtension: url.pathExtension) else { return }
        do {
            let cues = try Subtitles.parse(data, format: format, fallbackDuration: song.duration > 0 ? RationalTime(seconds: song.duration) : nil)
            edit.lines = cues.map { cue in
                LyricLine(start: cue.start, end: cue.end, text: cue.text.replacingOccurrences(of: "\n", with: " / "), wordTimes: cue.words.map { Optional($0.start) })
            }
            commit()
            editor.notify(.success, "Imported \(cues.count) lines. Give each one a picture.")
        } catch { editor.report(error) }
    }
}

// MARK: QA gate

struct QASection: View {
    @Bindable var editor: EditorModel
    let strip: ComicStrip?
    @State private var sheet: NSImage?
    @State private var zoom: NSImage?
    @State private var zoomedPanel: UUID?
    @AppStorage("comic.reviewer") private var reviewer = ""

    var body: some View {
        ComicPage(title: "QA Gate", subtitle: "Judge the image on its own against every check. Unsure means FAIL. Nothing exports until this passes.") {
            if let strip { lockBadge(strip) }
        } content: {
            if let strip, let comic = editor.project.comic {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            banner(strip)
                            ComicCard(title: "Contact sheet") {
                                if let sheet {
                                    Image(nsImage: sheet).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 360)
                                } else {
                                    Text("Detect or draw the panels to see the contact sheet.").font(Theme.Font.label).foregroundStyle(Theme.tertiary)
                                }
                            }
                            ComicCard(title: "Panels: what a stranger sees") {
                                ForEach(Array(strip.panels.enumerated()), id: \.element.id) { index, panel in PanelReviewRow(editor: editor, strip: strip, index: index, panel: panel, banned: comic.bannedWords) { showZoom(strip, panel) } }
                            }
                            if let zoom, zoomedPanel != nil {
                                ComicCard(title: "Panel at full size") { Image(nsImage: zoom).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 420) }
                            }
                            if !strip.rejected.isEmpty {
                                ComicCard(title: "Rejected attempts") {
                                    ForEach(strip.rejected) { attempt in
                                        HStack {
                                            Image(systemName: "xmark.octagon").foregroundStyle(Theme.danger)
                                            Text(attempt.fileName).font(Theme.Font.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text("Failed \(attempt.failedChecks.joined(separator: ", "))").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([editor.session.package.comicURL.appendingPathComponent("rejected/\(attempt.fileName)")]) }.buttonStyle(.kirieCompact)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(Theme.Space.l)
                    }
                    Divider1(vertical: true)
                    checklist(strip, comic).frame(width: 360)
                }
            } else {
                EmptyState(symbol: "checkmark.seal", title: "Nothing to review yet", message: "Import a strip in Strip & Panels. Its panels and the checklist appear here.")
            }
        }
        .task(id: strip?.panels) { refreshSheet() }
    }

    private func state(_ strip: ComicStrip) -> StripLockStatus? { editor.exportLock.strips.first { $0.stripID == strip.id } }

    @ViewBuilder private func lockBadge(_ strip: ComicStrip) -> some View {
        if editor.project.comic?.requireQAForExport == false {
            StatusBadge(text: "QA not required", symbol: "lock.open", tint: Theme.secondary)
        } else if let status = state(strip) {
            switch status.state {
            case .approved: StatusBadge(text: "PASS · export unlocked", symbol: "checkmark.seal.fill", tint: Theme.success)
            case .notApproved: StatusBadge(text: "Not approved · export locked", symbol: "lock.fill", tint: Theme.warning)
            case .staleImage: StatusBadge(text: "Image changed · export locked", symbol: "lock.fill", tint: Theme.warning)
            case .staleReview: StatusBadge(text: "Review changed · export locked", symbol: "lock.fill", tint: Theme.warning)
            case .unverifiable: StatusBadge(text: "Image missing · export locked", symbol: "lock.fill", tint: Theme.warning)
            }
        }
    }

    @ViewBuilder private func banner(_ strip: ComicStrip) -> some View {
        if let status = state(strip), status.state != .approved, editor.project.comic?.requireQAForExport != false {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "lock.fill").font(.system(size: 18)).foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export is locked").font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                    Text(status.message).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if status.state == .staleImage || status.state == .staleReview {
                        Text("The earlier PASS was for different content, so it no longer counts. Review what is here now and approve again.").font(Theme.Font.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.warningSoft))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.warning.opacity(0.6)))
            .accessibilityElement(children: .combine)
        } else if let approval = strip.approval, state(strip)?.state == .approved {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 18)).foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PASS  \(approval.imageHash.prefix(12))…").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                    Text("Approved by \(approval.approvedBy) on \(approval.approvedAt.formatted(date: .abbreviated, time: .shortened)). The hash is of the image file; if the file changes, this approval stops counting.")
                        .font(Theme.Font.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Revoke") { editor.perform(.comic(command: .revokeApproval(stripID: strip.id)), reload: false) }.buttonStyle(.kirieCompact)
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.success.opacity(0.5)))
        }
    }

    private func checklist(_ strip: ComicStrip, _ comic: ComicState) -> some View {
        let blockers = QAGate.approvalBlockers(strip: strip, comic: comic)
        let attempts = (try? editor.session.attemptStatus(stripID: strip.id)) ?? (1, comic.attemptLimit, false)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("CHECKLIST").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
                    ForEach(comic.checklist.items) { item in CheckRow(editor: editor, strip: strip, item: item, banned: comic.bannedWords) }
                }
                .padding(Theme.Space.m)
            }
            Divider1()
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Attempt \(attempts.0) of \(attempts.1)").font(Theme.Font.label).foregroundStyle(attempts.2 ? Theme.danger : Theme.secondary)
                    Spacer()
                    Toggle("Require QA to export", isOn: Binding(get: { comic.requireQAForExport }, set: { editor.perform(.comic(command: .setRequireQA(required: $0)), reload: false) }))
                        .toggleStyle(.checkbox).font(Theme.Font.label)
                }
                if attempts.2 { Text("The attempt limit is reached. Simplify the brief before drawing again.").font(Theme.Font.small).foregroundStyle(Theme.danger) }
                if blockers.isEmpty {
                    Label("Every check passes. Ready to approve.", systemImage: "checkmark.circle").font(Theme.Font.label).foregroundStyle(Theme.success)
                } else {
                    Text("\(blockers.count) thing\(blockers.count == 1 ? "" : "s") to resolve").font(Theme.Font.label).foregroundStyle(Theme.warning)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(blockers.prefix(12), id: \.self) { Text("• \($0)").font(Theme.Font.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    .frame(maxHeight: 84)
                }
                KirieField(placeholder: "Reviewer name", text: $reviewer)
                HStack {
                    Button("Reject this image") { reject(strip, comic) }.buttonStyle(.kirie)
                        .disabled(!comic.checklist.items.contains { strip.checks[$0.id]?.status == .fail } && !strip.panels.contains { $0.review.status == .fail })
                        .help("Keeps a copy of this image in the project with its failing checks in the file name")
                    Spacer()
                    Button { approve(strip) } label: { Label("Approve", systemImage: "checkmark.seal") }.buttonStyle(.kiriePrimary).disabled(!blockers.isEmpty)
                }
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.panel)
    }

    private func refreshSheet() {
        guard let strip, let image = try? editor.session.contactSheet(stripID: strip.id) else { sheet = nil; return }
        sheet = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func showZoom(_ strip: ComicStrip, _ panel: ComicPanel) {
        if zoomedPanel == panel.id { zoomedPanel = nil; return }
        guard let image = try? editor.session.panelZoom(stripID: strip.id, panelID: panel.id) else { return }
        zoom = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        zoomedPanel = panel.id
    }

    private func approve(_ strip: ComicStrip) {
        do {
            try editor.session.approveStrip(stripID: strip.id, approvedBy: reviewer)
            editor.syncFromSession(reload: false)
            editor.notify(.success, "Approved. Export is unlocked for this image.")
        } catch { editor.syncFromSession(reload: false); editor.report(error) }
    }

    private func reject(_ strip: ComicStrip, _ comic: ComicState) {
        guard let asset = editor.project.asset(strip.assetID), let url = editor.session.resolver.url(for: asset) else { return }
        let failed = comic.checklist.items.filter { strip.checks[$0.id]?.status == .fail }.map(\.id)
        do {
            let attempt = try editor.session.recordRejection(stripID: strip.id, imageURL: url, failedChecks: failed.isEmpty ? ["panel"] : failed,
                                                             note: strip.checks.values.first { $0.status == .fail }?.reason ?? "")
            editor.syncFromSession(reload: false)
            editor.notify(.info, "Kept as \(attempt.fileName). Replace the strip image with a new attempt, then review again.")
        } catch { editor.report(error) }
    }
}

struct StatusPicker: View {
    let status: ReviewStatus
    let set: (ReviewStatus) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([ReviewStatus.pass, .fail, .needsReview], id: \.self) { option in
                Button { set(option) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: option.symbol).font(.system(size: 9))
                        Text(option == .needsReview ? "?" : option.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(status == option ? option.tint : Theme.tertiary)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(status == option ? option.tint.opacity(0.16) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(status == option ? option.tint.opacity(0.6) : Theme.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.displayName).accessibilityAddTraits(status == option ? .isSelected : [])
            }
        }
    }
}

struct PanelReviewRow: View {
    let editor: EditorModel
    let strip: ComicStrip
    let index: Int
    let panel: ComicPanel
    let banned: [String]
    let zoom: () -> Void
    @State private var note = ""

    var body: some View {
        let flagged = QAGate.lintBannedWords(note, banned: banned)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.s) {
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).frame(width: 16)
                KirieField(placeholder: "One sentence, written from the image alone", text: $note) {
                    if note != panel.review.strangerNote { set(PanelReview(status: panel.review.status, strangerNote: note)) }
                }
                StatusPicker(status: panel.review.status) { set(PanelReview(status: $0, strangerNote: note)) }
                IconButton(symbol: "plus.magnifyingglass", label: "Zoom into panel \(index + 1)", size: 24, action: zoom)
            }
            if !flagged.isEmpty {
                Label("“\(flagged.joined(separator: "”, “"))”: if the note needs that word, the panel is a FAIL.", systemImage: "exclamationmark.triangle").font(Theme.Font.small).foregroundStyle(Theme.warning)
            }
        }
        .onAppear { note = panel.review.strangerNote }
        .onChange(of: panel.review.strangerNote) { _, new in note = new }
    }

    private func set(_ review: PanelReview) {
        editor.perform(.comic(command: .setPanelReview(stripID: strip.id, panelID: panel.id, review: review)), reload: false)
    }
}

struct CheckRow: View {
    let editor: EditorModel
    let strip: ComicStrip
    let item: QAChecklistItem
    let banned: [String]
    @State private var reason = ""

    var body: some View {
        let result = strip.checks[item.id] ?? CheckResult()
        let flagged = QAGate.lintBannedWords(reason, banned: banned)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.id).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(result.status.tint).frame(width: 16)
                Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                StatusPicker(status: result.status) { editor.perform(.comic(command: .setCheck(stripID: strip.id, itemID: item.id, result: CheckResult(status: $0, reason: reason))), reload: false) }
            }
            Text(item.detail).font(Theme.Font.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            KirieField(placeholder: "Reason", text: $reason) {
                if reason != result.reason { editor.perform(.comic(command: .setCheck(stripID: strip.id, itemID: item.id, result: CheckResult(status: result.status, reason: reason))), reload: false) }
            }
            if !flagged.isEmpty { Label("Soft-pass wording: “\(flagged.joined(separator: "”, “"))”", systemImage: "exclamationmark.triangle").font(Theme.Font.small).foregroundStyle(Theme.warning) }
        }
        .padding(Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .onAppear { reason = result.reason }
        .onChange(of: result.reason) { _, new in reason = new }
    }
}

// MARK: Export

struct ComicExportSection: View {
    @Bindable var editor: EditorModel
    let strip: ComicStrip?
    @State private var note = SongNote()
    @State private var posting = PostingDraft()
    @State private var shortlist = ""

    var body: some View {
        ComicPage(title: "Export", subtitle: "Video, carousel slides and the notes that go with a post.") {
            Button { editor.showExport = true } label: { Label("Export Video…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.kiriePrimary).disabled(editor.exportLock.isLocked || editor.sequence.duration.isZero)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if editor.exportLock.isLocked {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            Image(systemName: "lock.fill").font(.system(size: 18)).foregroundStyle(Theme.warning)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Export is locked until QA passes").font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                                ForEach(editor.exportLock.reasons, id: \.self) { Text($0).font(Theme.Font.body).foregroundStyle(Theme.text) }
                            }
                        }
                        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.warningSoft))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.warning.opacity(0.6)))
                    }
                    ComicCard(title: "Timeline to export") {
                        HStack {
                            Picker("Timeline", selection: Binding(get: { editor.project.activeSequenceID }, set: { editor.activate($0) })) {
                                ForEach(editor.project.sequences) { Text("\($0.name) · \(formatDuration($0.duration.seconds))").tag($0.id) }
                            }
                            .labelsHidden().frame(width: 320)
                            Button { editor.saveReelContactSheet() } label: { Label("Reel contact sheet…", systemImage: "square.grid.3x3") }.buttonStyle(.kirie)
                                .disabled(editor.sequence.duration.isZero)
                                .help("Twelve evenly spaced frames of this timeline in one image: a last check for cut-off characters and ghosted frames")
                        }
                    }
                    if let strip {
                        ComicCard(title: "Still images") {
                            HStack {
                                Button { exportCarousel(strip) } label: { Label("Export carousel slides", systemImage: "square.stack.3d.down.right") }.buttonStyle(.kirie)
                                    .disabled(editor.exportLock.isLocked || strip.panels.isEmpty)
                                Button { saveContactSheet(strip) } label: { Label("Save contact sheet…", systemImage: "square.grid.3x3") }.buttonStyle(.kirie).disabled(strip.panels.isEmpty)
                            }
                            Text("Carousel: one 1080×1350 slide per panel in reading order, on the page colour with a safe margin, then the full strip.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                            PlannedNote(text: "Webtoon scroll video.")
                        }
                    }
                    ComicCard(title: "Song note") {
                        Text("Commercial songs are never written into an export. Name the song here and Kirie saves a note next to the silent video, so you can add the track in the app when you post.")
                            .font(Theme.Font.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        KirieField(placeholder: "Song title", text: $note.title, onCommit: commitNote)
                        KirieField(placeholder: "Artist", text: $note.artist, onCommit: commitNote)
                        KirieField(placeholder: "Which part, for example: start at the chorus, 0:45", text: $note.section, onCommit: commitNote)
                    }
                    ComicCard(title: "Posting drafts") {
                        Text("Kept with the project for you to review and paste. Kirie does not post anything.").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                        draftEditor("Caption", $posting.caption)
                        draftEditor("Pinned comment", $posting.pinnedComment)
                        KirieField(placeholder: "Song shortlist, comma-separated", text: $shortlist) {
                            posting.songShortlist = shortlist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            commitPosting()
                        }
                    }
                }
                .padding(Theme.Space.xl).frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            note = editor.project.comic?.songNote ?? SongNote()
            posting = editor.project.comic?.posting ?? PostingDraft()
            shortlist = posting.songShortlist.joined(separator: ", ")
        }
        .onDisappear { commitNote(); commitPosting() }
    }

    private func draftEditor(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(Theme.Font.label).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.wrappedValue, forType: .string)
                    editor.notify(.success, "\(label) copied")
                }
                .buttonStyle(.kirieCompact).disabled(text.wrappedValue.isEmpty)
            }
            TextEditor(text: text).font(Theme.Font.body).scrollContentBackground(.hidden).frame(height: 64).padding(Theme.Space.xs)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        }
    }

    private func commitNote() {
        if editor.project.comic != nil, note != editor.project.comic?.songNote { editor.perform(.comic(command: .setSongNote(note: note)), reload: false) }
    }

    private func commitPosting() {
        if editor.project.comic != nil, posting != editor.project.comic?.posting { editor.perform(.comic(command: .setPosting(draft: posting)), reload: false) }
    }

    private func exportCarousel(_ strip: ComicStrip) {
        do {
            let slides = try editor.session.exportCarousel(stripID: strip.id)
            editor.notify(.success, "Exported \(slides.count) slides", actionTitle: "Show") { NSWorkspace.shared.activateFileViewerSelecting(Array(slides.prefix(1))) }
        } catch { editor.report(error) }
    }

    private func saveContactSheet(_ strip: ComicStrip) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(editor.project.comic?.folderName ?? "strip")-contact-sheet.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if Thumbnailer.write(try editor.session.contactSheet(stripID: strip.id), to: url) { editor.notify(.success, "Saved \(url.lastPathComponent)") }
        } catch { editor.report(error) }
    }
}
