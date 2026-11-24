import AVFoundation
import ComicStudio
import CoreGraphics
import Foundation
import MediaServices
import Persistence
import ProjectDomain
import RenderEngine

/// Resolves media through the project package (collected copies first, then original paths).
public struct PackageResolver: MediaResolving {
    public let package: ProjectPackage
    public init(package: ProjectPackage) { self.package = package }
    public func url(for asset: MediaAsset) -> URL? { package.resolve(asset.reference) }
}

public struct ImportFailure: Sendable, Equatable {
    public var fileName: String
    public var reason: String
}

public struct ImportResult: Sendable {
    public var assets: [MediaAsset]
    public var failures: [ImportFailure]
}

public enum ServiceError: Error, Equatable, LocalizedError {
    case notFound(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) was not found."
        case .invalid(let message): message
        }
    }
}

/// One open project: its package on disk plus the command engine. The app, the CLI and automation
/// all work through this type, so every edit goes through the same commands and the same checks.
public final class ProjectSession {
    public private(set) var package: ProjectPackage
    public var engine: CommandEngine
    /// Engine revision that was last written to disk.
    public private(set) var savedRevision: Int

    public var project: Project { engine.project }
    public var resolver: PackageResolver { PackageResolver(package: package) }
    public var hasUnsavedChanges: Bool { engine.revision != savedRevision }

    init(package: ProjectPackage, project: Project) {
        self.package = package
        self.engine = CommandEngine(project: project)
        self.savedRevision = engine.revision
    }

    // MARK: Lifecycle

    public static func create(at url: URL, name: String, canvas: CanvasSettings) throws -> ProjectSession {
        var target = url
        if target.pathExtension != ProjectPackage.fileExtension { target.appendPathExtension(ProjectPackage.fileExtension) }
        let project = Project(name: name, canvas: canvas)
        let problems = ProjectValidator.validate(project).filter { $0.severity == .error }.map(\.message)
        guard problems.isEmpty else { throw EditError.validationFailed(problems) }
        let package = try ProjectPackage.create(at: target, project: project)
        return ProjectSession(package: package, project: project)
    }

    public static func open(_ url: URL) throws -> (session: ProjectSession, opened: OpenedProject) {
        let opened = try ProjectPackage.open(url)
        let session = ProjectSession(package: opened.package, project: opened.project)
        if case .recoveredFromSnapshot = opened.source {
            // Make the recovered state the saved state straight away.
            try session.save()
        }
        return (session, opened)
    }

    /// Writes the current state. Safe to call often; each write is atomic.
    public func save() throws {
        try package.save(engine.project)
        savedRevision = engine.revision
    }

    @discardableResult
    public func execute(_ command: EditCommand, actor: CommandActor = .user, coalesceKey: String? = nil) throws -> CommandOutcome {
        try engine.execute(command, actor: actor, coalesceKey: coalesceKey)
    }

    @discardableResult
    public func execute(_ commands: [EditCommand], label: String, actor: CommandActor = .user) throws -> CommandOutcome {
        try engine.execute(commands, label: label, actor: actor)
    }

    // MARK: Snapshots

    @discardableResult
    public func createSnapshot(name: String, automatic: Bool = false) throws -> SnapshotInfo {
        try package.createSnapshot(engine.project, name: name, automatic: automatic)
    }

    public func restoreSnapshot(_ snapshot: SnapshotInfo) throws {
        let restored = try package.loadSnapshot(snapshot)
        // Keep a way back to where we were.
        try package.createSnapshot(engine.project, name: "Before restore", automatic: true)
        engine.load(restored)
        try save()
    }

    // MARK: Import

    public static let importLimit = 2_000

    /// Expands folders into the files they contain (one level of nesting is followed).
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                files.append(url)
                continue
            }
            if isDirectory.boolValue, url.pathExtension != ProjectPackage.fileExtension {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files.append(contentsOf: children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    .filter { MediaProbe.kind(of: $0) != nil })
            } else {
                files.append(url)
            }
        }
        return Array(files.prefix(importLimit))
    }

    /// Probes files and builds assets. Nothing is added to the project until the returned assets are
    /// passed to an `importAssets` command; every file that could not be imported is reported.
    public func prepareImport(_ urls: [URL], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ImportResult {
        let files = ProjectSession.expand(urls)
        var assets: [MediaAsset] = []
        var failures: [ImportFailure] = []
        let existing = Set(engine.project.assets.map { $0.reference.absolutePath })
        for (index, url) in files.enumerated() {
            if Task.isCancelled { break }
            progress?(index, files.count)
            let standard = url.standardizedFileURL
            if existing.contains(standard.path) || assets.contains(where: { $0.reference.absolutePath == standard.path }) { continue }
            do {
                let (kind, metadata) = try await MediaProbe.probe(standard)
                let print = try FileHasher.fingerprint(of: standard)
                var reference = MediaReference(absolutePath: standard.path, fileSize: print.size, fingerprint: print.fingerprint)
                if standard.path.hasPrefix(package.url.path + "/") {
                    reference.relativePath = String(standard.path.dropFirst(package.url.path.count + 1))
                }
                assets.append(MediaAsset(name: standard.lastPathComponent, kind: kind, reference: reference, metadata: metadata))
            } catch {
                failures.append(ImportFailure(fileName: url.lastPathComponent, reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        progress?(files.count, files.count)
        return ImportResult(assets: assets, failures: failures)
    }

    /// Probes and imports in one step. Returns what was imported and what failed.
    @discardableResult
    public func importFiles(_ urls: [URL], actor: CommandActor = .user) async throws -> ImportResult {
        let result = await prepareImport(urls)
        if !result.assets.isEmpty { try execute(.importAssets(assets: result.assets), actor: actor) }
        return result
    }

    // MARK: Collect / relink

    public func collectMedia() throws -> CollectReport {
        let (references, report) = try package.collect(engine.project)
        let commands = engine.project.assets.compactMap { asset -> EditCommand? in
            guard let reference = references[asset.id], reference != asset.reference else { return nil }
            return .relinkAsset(assetID: asset.id, reference: reference)
        }
        if !commands.isEmpty { try execute(commands, label: "Collect media") }
        try save()
        return report
    }

    public func relink(assetID: UUID, to url: URL) async throws {
        guard let asset = engine.project.asset(assetID) else { throw ServiceError.notFound("The media item") }
        let (kind, metadata) = try await MediaProbe.probe(url)
        guard kind == asset.kind else { throw ServiceError.invalid("“\(url.lastPathComponent)” is \(kind.rawValue), but “\(asset.name)” is \(asset.kind.rawValue).") }
        if asset.kind != .image, abs(metadata.duration.seconds - asset.metadata.duration.seconds) > 0.25 {
            throw ServiceError.invalid("“\(url.lastPathComponent)” is \(String(format: "%.1f", metadata.duration.seconds)) s long, but the missing file was \(String(format: "%.1f", asset.metadata.duration.seconds)) s. Clips could run past its end.")
        }
        let print = try FileHasher.fingerprint(of: url)
        try execute(.relinkAsset(assetID: assetID, reference: MediaReference(absolutePath: url.standardizedFileURL.path, fileSize: print.size, fingerprint: print.fingerprint)))
    }

    // MARK: Beats

    public func analyseBeats(assetID: UUID) async throws -> BeatAnalysis {
        guard let asset = engine.project.asset(assetID), let url = resolver.url(for: asset) else { throw ServiceError.notFound("The audio file") }
        let analysis = try await BeatDetector.analyse(url)
        guard analysis.bpm > 0 else { throw ServiceError.invalid("No steady beat was found in “\(asset.name)”.") }
        return analysis
    }

    /// Detects beats in the audio clip and returns the command that puts them on the timeline.
    public func beatMarkersCommand(forClip clipID: UUID) async throws -> (command: EditCommand, analysis: BeatAnalysis) {
        guard let location = engine.project.locateClip(clipID) else { throw EditError.clipNotFound(clipID) }
        let sequence = engine.project.sequences[location.sequence]
        let clip = sequence.tracks[location.track].clips[location.clip]
        guard let assetID = clip.assetID else { throw ServiceError.invalid("Choose an audio or video clip.") }
        let analysis = try await analyseBeats(assetID: assetID)
        var scaled = analysis
        if clip.speed != 1 { scaled.beats = analysis.beats.map { $0 / clip.speed } }
        let markers = scaled.markers(offset: clip.start, sourceStart: clip.speed == 1 ? clip.sourceStart : clip.sourceStart.scaled(by: 1 / clip.speed),
                                     limit: clip.duration, seed: clipID)
        return (.replaceBeatMarkers(sequenceID: sequence.id, markers: markers), analysis)
    }

    // MARK: Captions

    public func captionsCommand(fromSubtitleFile url: URL, trackID: UUID? = nil, style: TextStyle = .caption,
                                animation: TextAnimation = .none) throws -> EditCommand {
        guard let format = SubtitleFormat(fileExtension: url.pathExtension) else {
            throw ServiceError.invalid("Kirie reads SRT, VTT and LRC caption files.")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ServiceError.notFound("The caption file") }
        let segments = try Subtitles.parse(data, format: format, fallbackDuration: engine.project.activeSequence.duration)
        let sequence = engine.project.activeSequence
        let track = trackID ?? sequence.tracks.first { $0.kind == .caption }?.id ?? UUID()
        return .replaceCaptions(sequenceID: sequence.id, trackID: track, segments: segments, style: style, animation: animation)
    }

    /// The caption track of a sequence as absolute-time segments.
    public static func captionSegments(in sequence: Sequence, trackID: UUID? = nil) -> [CaptionSegment] {
        let tracks = sequence.tracks.filter { $0.kind == .caption && (trackID == nil || $0.id == trackID) }
        return tracks.flatMap(\.clips).sorted { $0.start < $1.start }.compactMap { clip in
            guard let text = clip.text else { return nil }
            let words = text.words.map { TimedWord(text: $0.text, start: $0.start + clip.start, end: $0.end + clip.start) }
            return CaptionSegment(start: clip.start, end: clip.end, text: text.string, words: words)
        }
    }

    public func exportCaptions(format: SubtitleFormat) -> String {
        Subtitles.write(ProjectSession.captionSegments(in: engine.project.activeSequence), format: format)
    }

    // MARK: Export

    /// Current SHA-256 of every strip image (missing files are simply absent from the result).
    public func stripImageHashes() -> [UUID: String] {
        var hashes: [UUID: String] = [:]
        for strip in engine.project.comic?.strips ?? [] {
            guard let asset = engine.project.asset(strip.assetID), let url = resolver.url(for: asset),
                  let hash = try? FileHasher.sha256(of: url) else { continue }
            hashes[strip.assetID] = hash
        }
        return hashes
    }

    public func exportLock() -> ExportLockStatus {
        QAGate.exportLock(project: engine.project, imageHashes: stripImageHashes())
    }

    public func defaultExportURL(preset: ExportPreset, name: String? = nil) -> URL {
        let base = (name ?? engine.project.name).map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return package.exportsURL.appendingPathComponent("\(String(base)).\(preset.container.fileExtension)")
    }

    /// Exports the active (or given) sequence. Refuses while the Comic Studio export lock is engaged.
    public func export(preset: ExportPreset, to destination: URL? = nil, sequenceID: UUID? = nil, range: TimeRange? = nil,
                       options: RenderOptions = RenderOptions(), cancellation: ExportCancellation = ExportCancellation(),
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExportReport {
        let lock = exportLock()
        guard !lock.isLocked else { throw RenderError.exportLocked(lock.reasons) }
        let target = destination ?? defaultExportURL(preset: preset)
        let note = engine.project.comic?.songNote
        let request = ExportRequest(preset: preset, destination: target, range: range, options: options, songNote: note)
        return try await Exporter.export(project: engine.project, sequenceID: sequenceID, resolver: resolver, request: request,
                                         cancellation: cancellation, progress: progress)
    }

    public func buildComposition(sequenceID: UUID? = nil, outputSize: CGSize? = nil, options: RenderOptions = RenderOptions(excludeUnlicensedAudio: false)) async throws -> BuiltComposition {
        try await CompositionBuilder.build(project: engine.project, sequenceID: sequenceID, resolver: resolver, outputSize: outputSize, options: options)
    }
}
