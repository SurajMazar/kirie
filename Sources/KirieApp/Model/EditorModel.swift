import AppKit
import AVFoundation
import ComicStudio
import Foundation
import KirieServices
import MediaServices
import Observation
import Persistence
import ProjectDomain
import RenderEngine

enum SaveState: Equatable {
    case saved, unsaved, saving
    case failed(String)

    var label: String {
        switch self {
        case .saved: "Saved"
        case .unsaved: "Edited"
        case .saving: "Saving…"
        case .failed: "Not saved"
        }
    }
}

enum SafeZone: String, CaseIterable, Identifiable {
    case off, reels, tiktok, shorts
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .reels: "Instagram Reels"
        case .tiktok: "TikTok"
        case .shorts: "YouTube Shorts"
        }
    }
    /// Approximate interface cover as fractions of a 9:16 frame: top, bottom, right column.
    var insets: (top: Double, bottom: Double, trailing: Double) {
        switch self {
        case .off: (0, 0, 0)
        case .reels: (0.115, 0.22, 0.11)
        case .tiktok: (0.07, 0.25, 0.11)
        case .shorts: (0.08, 0.23, 0.11)
        }
    }
}

enum EditorWorkspace: String { case edit, comic }

/// State and actions for one open project. Views read from here and call these methods; every
/// change to the project goes through `perform`, which runs a typed command on the shared engine.
@MainActor
@Observable
final class EditorModel {
    let session: ProjectSession
    let player = PlayerController()
    let cache = MediaCache()

    private(set) var project: Project
    var selection: Set<UUID> = []
    var selectedAssetID: UUID?
    var zoom: Double = 80
    var snapping = true
    var quality: PreviewQuality = .half { didSet { reloadPlayer() } }
    var safeZone: SafeZone = .off
    var workspace: EditorWorkspace = .edit
    private(set) var saveState: SaveState = .saved
    private(set) var toasts: [Toast] = []
    private(set) var activity: [String] = []
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoLabel: String?
    private(set) var redoLabel: String?
    private(set) var missingMedia: [MediaAsset] = []
    private(set) var exportLock: ExportLockStatus = .unlocked
    var showExport = false

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored var onSaved: ((Project) -> Void)?

    init(session: ProjectSession) {
        self.session = session
        self.project = session.project
        FontLibrary.registerAll(in: session)
        refresh(reload: true)
    }

    var sequence: ProjectDomain.Sequence { project.activeSequence }
    var playhead: RationalTime { player.currentTime }
    var frameRate: FrameRate { project.canvas.frameRate }

    var selectedClips: [Clip] { sequence.allClips.filter { selection.contains($0.id) } }
    var primaryClip: Clip? { selection.count == 1 ? selectedClips.first : nil }

    // MARK: Commands

    private func refresh(reload: Bool) {
        project = session.project
        canUndo = session.engine.canUndo
        canRedo = session.engine.canRedo
        undoLabel = session.engine.undoLabel
        redoLabel = session.engine.redoLabel
        let known = Set(sequence.allClips.map(\.id))
        selection = selection.intersection(known)
        missingMedia = session.package.missingAssets(in: project)
        exportLock = session.exportLock()
        if reload { reloadPlayer() }
    }

    /// Runs a command. Errors become a notification instead of a crash or a silent no-op.
    @discardableResult
    func perform(_ command: EditCommand, coalesce: String? = nil, reload: Bool = true) -> Bool {
        perform([command], label: nil, coalesce: coalesce, reload: reload)
    }

    @discardableResult
    func perform(_ commands: [EditCommand], label: String?, coalesce: String? = nil, reload: Bool = true) -> Bool {
        do {
            if let label {
                try session.execute(commands, label: label)
            } else if let first = commands.first, commands.count == 1 {
                try session.execute(first, coalesceKey: coalesce)
            } else {
                try session.execute(commands, label: "Edit")
            }
            refresh(reload: reload)
            scheduleSave()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Ends a slider drag so the next change starts a new undo step.
    func endGesture() { session.engine.breakCoalescing() }

    func undo() {
        guard session.engine.canUndo else { return }
        do {
            let outcome = try session.engine.undo()
            refresh(reload: true)
            scheduleSave()
            notify(.info, "Undid “\(outcome.entry.label)”")
        } catch { report(error) }
    }

    func redo() {
        guard session.engine.canRedo else { return }
        do {
            let outcome = try session.engine.redo()
            refresh(reload: true)
            scheduleSave()
            notify(.info, "Redid “\(outcome.entry.label)”")
        } catch { report(error) }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveState = .unsaved
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard session.hasUnsavedChanges || saveState != .saved else { return }
        saveState = .saving
        do {
            try session.save()
            saveState = .saved
            onSaved?(session.project)
        } catch {
            saveState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            notify(.error, "Could not save: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)", actionTitle: "Try again") { [weak self] in self?.saveNow() }
        }
    }

    // MARK: Notifications and activity

    func notify(_ kind: Toast.Kind, _ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(kind: kind, message: message, actionTitle: actionTitle, action: action)
        toasts.append(toast)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        let lifetime: UInt64 = kind == .error || action != nil ? 9_000_000_000 : 3_500_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: lifetime)
            self?.dismiss(toast)
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func dismiss(_ toast: Toast) { toasts.removeAll { $0.id == toast.id } }

    func report(_ error: Error) {
        notify(.error, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func track<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        activity.append(label)
        defer { if let index = activity.firstIndex(of: label) { activity.remove(at: index) } }
        return try await work()
    }

    // MARK: Playback

    func reloadPlayer() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            // Coalesce bursts of edits (slider drags) into one rebuild.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, !Task.isCancelled else { return }
            self.player.reload(session: self.session, quality: self.quality)
        }
    }

    // MARK: Import

    func importFiles(_ urls: [URL], addToTimeline: Bool = false) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await track("Importing media") { await session.prepareImport(urls) }
            if !result.assets.isEmpty {
                var commands: [EditCommand] = [.importAssets(assets: result.assets)]
                if addToTimeline {
                    commands += result.assets.map { .addClip(sequenceID: nil, clipID: UUID(), assetID: $0.id, trackID: nil, start: nil, sourceStart: nil, duration: nil, index: nil) }
                }
                perform(commands, label: result.assets.count == 1 ? "Import \(result.assets[0].name)" : "Import \(result.assets.count) items")
                selectedAssetID = result.assets.first?.id
            }
            if !result.failures.isEmpty {
                let first = result.failures[0]
                let more = result.failures.count > 1 ? " (and \(result.failures.count - 1) more)" : ""
                notify(.warning, "\(first.reason)\(more)")
            } else if result.assets.isEmpty {
                notify(.info, "Those files are already in the project.")
            } else {
                notify(.success, result.assets.count == 1 ? "Imported \(result.assets[0].name)" : "Imported \(result.assets.count) items")
            }
        }
    }

    func chooseFilesToImport(addToTimeline: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.message = "Choose video, audio or images to import"
        panel.prompt = "Import"
        if panel.runModal() == .OK { importFiles(panel.urls, addToTimeline: addToTimeline) }
    }

    // MARK: Timeline actions

    func addToTimeline(_ assetID: UUID, trackID: UUID? = nil, start: RationalTime? = nil) {
        guard let asset = project.asset(assetID) else { return }
        let id = UUID()
        // Audio goes to an audio track at the playhead; pictures join the end of the main track.
        let at = start ?? (asset.kind == .audio ? playhead.rounded(toFrame: frameRate) : nil)
        if perform(.addClip(sequenceID: nil, clipID: id, assetID: assetID, trackID: trackID, start: at, sourceStart: nil, duration: nil, index: nil)) {
            selection = [id]
        }
    }

    func splitAtPlayhead() {
        let time = playhead.rounded(toFrame: frameRate)
        var targets = selectedClips.filter { $0.range.contains(time) && $0.start != time }
        if targets.isEmpty, let main = sequence.mainTrack?.clips.first(where: { $0.range.contains(time) && $0.start != time }) { targets = [main] }
        guard !targets.isEmpty else {
            notify(.info, "Move the playhead inside a clip to split it.")
            return
        }
        perform(targets.map { .splitClip(clipID: $0.id, at: time, newClipID: UUID()) }, label: "Split clip")
    }

    func deleteSelection(ripple: Bool) {
        guard !selection.isEmpty else { return }
        perform(.removeClips(clipIDs: sequence.allClips.filter { selection.contains($0.id) }.map(\.id), ripple: ripple))
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let copies = selectedClips.map { ($0.id, UUID()) }
        if perform(copies.map { .duplicateClip(clipID: $0.0, newClipID: $0.1) }, label: "Duplicate") { selection = Set(copies.map(\.1)) }
    }

    func selectAll() { selection = Set(sequence.allClips.map(\.id)) }

    func addMarker() {
        perform(.addMarkers(sequenceID: nil, markers: [Marker(time: playhead.rounded(toFrame: frameRate))]))
    }

    func addText(_ string: String, role: TextRole = .title, style: TextStyle, animation: TextAnimation = .none, position: UnitPoint2D = .center,
                 duration: Double = 3) {
        let start = playhead.rounded(toFrame: frameRate)
        var clip = Clip(kind: .text, name: string, start: start, duration: RationalTime(seconds: duration),
                        text: TextContent(string: string, role: role, style: style, animation: animation))
        clip.transform.position = position
        // Find a text track with room at the playhead, or make one.
        let track = sequence.tracks.first { $0.kind == .text && !$0.locked && !$0.hasOverlap(clip.range) }
        if perform(.insertClip(sequenceID: nil, trackID: track?.id, clip: clip, index: nil)) { selection = [clip.id] }
    }

    func addOverlay(_ assetID: UUID) {
        guard let asset = project.asset(assetID), asset.kind != .audio else { return }
        let start = playhead.rounded(toFrame: frameRate)
        let id = UUID()
        var commands: [EditCommand] = []
        let length = asset.kind == .image ? RationalTime(seconds: 3) : asset.metadata.duration
        var trackID = sequence.tracks.first { $0.kind == .overlay && !$0.locked && !$0.hasOverlap(TimeRange(start: start, duration: length)) }?.id
        if trackID == nil {
            let created = UUID()
            commands.append(.addTrack(sequenceID: nil, trackID: created, kind: .overlay, name: nil, index: nil))
            trackID = created
        }
        commands.append(.addClip(sequenceID: nil, clipID: id, assetID: assetID, trackID: trackID, start: start, sourceStart: nil, duration: nil, index: nil))
        if perform(commands, label: "Add overlay") { selection = [id] }
    }

    // MARK: Audio and captions

    func detectBeats(forClip clipID: UUID) {
        Task {
            do {
                let (command, analysis) = try await track("Finding the beat") { try await session.beatMarkersCommand(forClip: clipID) }
                var commands = [command]
                if let assetID = sequence.clip(clipID)?.assetID {
                    commands.append(.updateAssetInfo(assetID: assetID, name: nil, rights: nil, favourite: nil, rating: nil, keywords: nil, bpm: analysis.bpm))
                }
                perform(commands, label: "Detect beats")
                notify(.success, String(format: "%.0f BPM, %d beats marked", analysis.bpm, sequence.beatTimes.count))
            } catch { report(error) }
        }
    }

    func cutToBeat(every: Int) {
        let main = sequence.mainTrack?.clips ?? []
        let targets = selection.isEmpty ? main : main.filter { selection.contains($0.id) }
        guard !targets.isEmpty else {
            notify(.info, "Add clips to the main track first.")
            return
        }
        perform(.cutToBeat(clipIDs: targets.map(\.id), every: every))
    }

    func importCaptions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "vtt", "lrc"].compactMap { .init(filenameExtension: $0) }
        panel.message = "Choose an SRT, VTT or LRC file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            perform(try session.captionsCommand(fromSubtitleFile: url, animation: .none))
            notify(.success, "Captions imported")
        } catch { report(error) }
    }

    func exportCaptions(_ format: SubtitleFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.exportCaptions(format: format).write(to: url, atomically: true, encoding: .utf8)
            notify(.success, "Captions saved as \(url.lastPathComponent)")
        } catch { report(error) }
    }

    func autoCaption(clipID: UUID) {
        Task {
            do {
                let command = try await track("Transcribing on this Mac") { try await session.autoCaptionsCommand(forClip: clipID) }
                perform(command)
                notify(.success, "Captions added. Review them in the Captions panel.")
            } catch { report(error) }
        }
    }

    // MARK: Stills

    /// Saves the frame under the playhead at full canvas resolution (a cover image, for example).
    func saveFrame() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name) \(Timecode.string(playhead, rate: frameRate).replacingOccurrences(of: ":", with: "-")).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let time = RationalTime.min(playhead, sequence.duration - frameRate.frameDuration).floored(toFrame: frameRate)
        Task {
            do {
                let image = try await track("Rendering the frame") {
                    let built = try await session.buildComposition()
                    return try await Exporter.still(built: built, at: RationalTime.max(.zero, time))
                }
                if Thumbnailer.write(image, to: url) { notify(.success, "Saved \(url.lastPathComponent)") } else { notify(.error, "The image could not be saved.") }
            } catch { report(error) }
        }
    }

    /// Evenly spaced frames of the active timeline in one image, for a last look before export.
    func saveReelContactSheet() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sequence.name) contact sheet.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let sheet = try await track("Rendering the contact sheet") {
                    let built = try await session.buildComposition(outputSize: CGSize(width: 270, height: (270 / project.canvas.aspectRatio / 2).rounded() * 2))
                    return try await ComicSheets.reelContactSheet(built: built, frames: 12)
                }
                if let sheet, Thumbnailer.write(sheet, to: url) {
                    notify(.success, "Saved \(url.lastPathComponent)", actionTitle: "Open") { NSWorkspace.shared.open(url) }
                } else {
                    notify(.error, "The contact sheet could not be saved.")
                }
            } catch { report(error) }
        }
    }

    // MARK: Sequences

    func activate(_ sequenceID: UUID) {
        guard sequenceID != project.activeSequenceID else { return }
        player.pause()
        selection = []
        perform(.setActiveSequence(sequenceID: sequenceID))
        player.seek(to: .zero)
    }

    func createSnapshot(named name: String) {
        do {
            try session.createSnapshot(name: name)
            notify(.success, "Snapshot “\(name)” saved")
        } catch { report(error) }
    }

    func restore(_ snapshot: SnapshotInfo) {
        do {
            try session.restoreSnapshot(snapshot)
            selection = []
            refresh(reload: true)
            saveState = .saved
            notify(.success, "Restored “\(snapshot.name)”. The previous state was kept as a snapshot.")
        } catch { report(error) }
    }

    /// Call after services that execute commands themselves (Comic Studio builders, collect, relink).
    func syncFromSession(reload: Bool = true) {
        refresh(reload: reload)
        scheduleSave()
    }

    func relink(_ asset: MediaAsset) {
        let panel = NSOpenPanel()
        panel.message = "Find “\(asset.name)”"
        panel.prompt = "Relink"
        // Offer the most likely replacement first.
        panel.directoryURL = URL(fileURLWithPath: (asset.reference.absolutePath as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await session.relink(assetID: asset.id, to: url)
                cache.reset()
                syncFromSession()
                notify(.success, "Relinked \(asset.name)")
            } catch { report(error) }
        }
    }
}
