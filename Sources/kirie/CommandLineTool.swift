import ComicStudio
import Foundation
import KirieServices
import MediaServices
import Persistence
import ProjectDomain
import RenderEngine

/// Exit codes are part of the CLI contract.
enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    case notFound = 3
    case rejected = 4
    case exportLocked = 5
    case exportFailed = 6
    case cancelled = 130
}

struct CLIError: Error {
    var code: ExitCode
    var identifier: String
    var message: String
}

/// Parsed arguments: positionals plus `--name value` and `--flag` options.
struct Arguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let booleanFlags: Set<String> = ["dry-run", "silent", "reduce-motion", "vary", "purge", "pretty", "compact", "right-to-left",
                                            "no-full-strip", "confirm", "help", "manga"]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--"), token.count > 2 {
                let name = String(token.dropFirst(2))
                if Arguments.booleanFlags.contains(name) {
                    flags.insert(name)
                } else {
                    guard index + 1 < raw.count else { throw CLIError(code: .usage, identifier: "usage", message: "Option --\(name) needs a value.") }
                    options[name] = raw[index + 1]
                    index += 1
                }
            } else {
                positionals.append(token)
            }
            index += 1
        }
    }

    func require(_ position: Int, _ what: String) throws -> String {
        guard position < positionals.count else { throw CLIError(code: .usage, identifier: "usage", message: "Missing \(what). Run `kirie help`.") }
        return positionals[position]
    }

    func double(_ name: String) throws -> Double? {
        guard let raw = options[name] else { return nil }
        guard let value = Double(raw), value.isFinite else { throw CLIError(code: .usage, identifier: "usage", message: "--\(name) must be a number.") }
        return value
    }
}

enum CommandLineTool {
    static let usage = """
    kirie — command-line interface to Kirie projects. Output is JSON on stdout; progress on stderr.

    Projects
      kirie new <path> [--name N] [--preset vertical|portrait|square|landscape|cinema] [--size WxH] [--fps 30]
      kirie info <project>                     Summary: canvas, media, timelines, export lock
      kirie timeline <project> [--sequence S]  Tracks, clips and markers of a timeline
      kirie validate <project>                 Structural checks (exit 4 if invalid)
      kirie import <project> <file|folder>...  Probe and import media
      kirie apply <project> (--command JSON | --file PATH) [--dry-run] [--confirm]
                                               Run typed edit commands (the same ones the app uses)
      kirie collect <project>                  Copy referenced media into the package
      kirie snapshot <project> create [name] | list | restore <file-name>
      kirie storage <project> [--purge]        Cache sizes; --purge clears regenerable data

    Media
      kirie probe <file>                       Technical metadata
      kirie beats <audio-file>                 Tempo and beat times
      kirie beats <project> --clip ID          Detect beats under a clip and add beat markers
      kirie captions <project> import <file.srt|vtt|lrc>
      kirie captions <project> export --format srt|vtt|lrc [--out FILE]

    Export
      kirie presets                            Built-in export presets
      kirie export <project> [--preset ID] [--out FILE] [--sequence S] [--from SEC] [--to SEC] [--silent] [--reduce-motion]

    Comic Studio
      kirie comic detect <image> [--manga]     Detect panels in an image
      kirie comic add-strip <project> <asset name or id> [--number N] [--slug S] [--manga]
      kirie comic status <project>             QA state, blockers and export lock
      kirie comic review <project> --panel N --status PASS|FAIL|NEEDS_REVIEW --note TEXT [--strip ID]
      kirie comic check <project> --item A --status PASS|FAIL --reason TEXT [--strip ID]
      kirie comic approve <project> --by NAME [--strip ID]
      kirie comic reel <project> [--strip ID] [--vary]
      kirie comic contact-sheet <project> --out FILE.png [--strip ID]
      kirie comic carousel <project> [--out DIR] [--no-full-strip] [--strip ID]
      kirie comic wireframe <panels 2-5> --out FILE.png

    Other
      kirie demo <directory>                   Build the demo project from generated media
      kirie mcp <project>                      Model Context Protocol server on stdio, scoped to one project
      kirie version | help

    Exit codes: 0 ok, 1 error, 2 usage, 3 not found, 4 rejected or invalid, 5 export locked, 6 export failed, 130 cancelled.
    """

    static func emit(_ value: JSONValue, compact: Bool = false) {
        FileHandle.standardOutput.write(Data((value.serialised(pretty: !compact) + "\n").utf8))
    }

    static func progress(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func run(arguments raw: [String]) async -> Int32 {
        let compact = raw.contains("--compact")
        do {
            let arguments = try Arguments(raw)
            if arguments.positionals.isEmpty || arguments.flags.contains("help") || arguments.positionals.first == "help" {
                print(usage)
                return ExitCode.success.rawValue
            }
            let result = try await dispatch(arguments)
            emit(.object(["ok": .bool(true), "result": result]), compact: compact)
            return ExitCode.success.rawValue
        } catch let error as CLIError {
            emit(.object(["ok": .bool(false), "error": .object(["code": .string(error.identifier), "message": .string(error.message)])]), compact: compact)
            return error.code.rawValue
        } catch {
            let mapped = map(error)
            emit(.object(["ok": .bool(false), "error": .object(["code": .string(mapped.identifier), "message": .string(mapped.message)])]), compact: compact)
            return mapped.code.rawValue
        }
    }

    static func map(_ error: Error) -> CLIError {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        switch error {
        case let render as RenderError:
            switch render {
            case .exportLocked: return CLIError(code: .exportLocked, identifier: "export_locked", message: message)
            case .cancelled: return CLIError(code: .cancelled, identifier: "cancelled", message: message)
            case .missingMedia: return CLIError(code: .notFound, identifier: "missing_media", message: message)
            case .invalidPreset, .emptyTimeline: return CLIError(code: .rejected, identifier: "invalid_export", message: message)
            default: return CLIError(code: .exportFailed, identifier: "export_failed", message: message)
            }
        case let edit as EditError:
            switch edit {
            case .clipNotFound, .trackNotFound, .assetNotFound, .sequenceNotFound, .markerNotFound, .stripNotFound, .panelNotFound:
                return CLIError(code: .notFound, identifier: "not_found", message: message)
            default: return CLIError(code: .rejected, identifier: "rejected", message: message)
            }
        case is ProjectFileError: return CLIError(code: .rejected, identifier: "invalid_project", message: message)
        case let persistence as PersistenceError:
            if case .notAPackage = persistence { return CLIError(code: .notFound, identifier: "not_found", message: message) }
            return CLIError(code: .failure, identifier: "storage", message: message)
        case let media as MediaError:
            if case .missing = media { return CLIError(code: .notFound, identifier: "not_found", message: message) }
            return CLIError(code: .rejected, identifier: "unsupported_media", message: message)
        case is SubtitleError, is ServiceError: return CLIError(code: .rejected, identifier: "rejected", message: message)
        case is DecodingError: return CLIError(code: .usage, identifier: "bad_command", message: "The command JSON does not match any Kirie command. \(message)")
        default: return CLIError(code: .failure, identifier: "error", message: message)
        }
    }

    // MARK: Helpers

    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func open(_ path: String) throws -> ProjectSession {
        var url = fileURL(path)
        if !FileManager.default.fileExists(atPath: url.path), url.pathExtension.isEmpty { url.appendPathExtension(ProjectPackage.fileExtension) }
        return try ProjectSession.open(url).session
    }

    static func sequence(_ session: ProjectSession, _ selector: String?) throws -> ProjectDomain.Sequence {
        guard let selector else { return session.project.activeSequence }
        if let id = UUID(uuidString: selector), let found = session.project.sequence(id) { return found }
        if let found = session.project.sequences.first(where: { $0.name.caseInsensitiveCompare(selector) == .orderedSame }) { return found }
        throw CLIError(code: .notFound, identifier: "not_found", message: "No timeline named “\(selector)”.")
    }

    static func strip(_ session: ProjectSession, _ selector: String?) throws -> ComicStrip {
        guard let comic = session.project.comic, !comic.strips.isEmpty else {
            throw CLIError(code: .notFound, identifier: "not_found", message: "This project has no comic strip. Use `kirie comic add-strip`.")
        }
        if let selector {
            guard let id = UUID(uuidString: selector), let strip = comic.strip(id) else {
                throw CLIError(code: .notFound, identifier: "not_found", message: "No strip with id \(selector).")
            }
            return strip
        }
        return comic.strips[0]
    }

    static func status(_ raw: String?) throws -> ReviewStatus {
        guard let raw, let status = ReviewStatus(rawValue: raw.uppercased().replacingOccurrences(of: " ", with: "_")) else {
            throw CLIError(code: .usage, identifier: "usage", message: "--status must be PASS, FAIL or NEEDS_REVIEW.")
        }
        return status
    }

    // MARK: Dispatch

    static func dispatch(_ arguments: Arguments) async throws -> JSONValue {
        let command = arguments.positionals[0]
        switch command {
        case "version":
            return .object(["version": .string(ProjectPackage.appVersion), "schemaVersion": .int(SchemaVersion.current)])

        case "new":
            let url = fileURL(try arguments.require(1, "the project path"))
            var canvas = CanvasSettings(width: 1080, height: 1920)
            if let presetID = arguments.options["preset"] {
                guard let preset = CanvasPreset.named(presetID) else {
                    throw CLIError(code: .usage, identifier: "usage", message: "Unknown canvas preset “\(presetID)”. Use \(CanvasPreset.all.map(\.id).joined(separator: ", ")).")
                }
                canvas.width = preset.width
                canvas.height = preset.height
            }
            if let size = arguments.options["size"] {
                let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2 else { throw CLIError(code: .usage, identifier: "usage", message: "--size must look like 1080x1920.") }
                canvas.width = parts[0]
                canvas.height = parts[1]
            }
            if let fps = try arguments.double("fps") {
                guard let rate = FrameRate.common.first(where: { abs($0.fps - fps) < 0.01 }) else {
                    throw CLIError(code: .usage, identifier: "usage", message: "--fps must be one of \(FrameRate.common.map(\.description).joined(separator: ", ")).")
                }
                canvas.frameRate = rate
            }
            let name = arguments.options["name"] ?? url.deletingPathExtension().lastPathComponent
            let session = try ProjectSession.create(at: url, name: name, canvas: canvas)
            return Inspection.project(session)

        case "info":
            return Inspection.project(try open(try arguments.require(1, "the project path")))

        case "timeline":
            let session = try open(try arguments.require(1, "the project path"))
            return Inspection.timeline(try sequence(session, arguments.options["sequence"]))

        case "validate":
            let url = fileURL(try arguments.require(1, "the project path"))
            guard let data = FileManager.default.contents(atPath: ProjectPackage(url: url).projectURL.path) else {
                throw CLIError(code: .notFound, identifier: "not_found", message: "“\(url.lastPathComponent)” is not a Kirie project.")
            }
            let project = try ProjectCodec.decode(data, validate: false)
            let issues = ProjectValidator.validate(project)
            let errors = issues.filter { $0.severity == .error }
            let report = JSONValue.object(["valid": .bool(errors.isEmpty), "issues": .array(issues.map {
                .object(["severity": .string($0.severity.rawValue), "message": .string($0.message)])
            })])
            if !errors.isEmpty {
                emit(.object(["ok": .bool(false), "result": report, "error": .object(["code": .string("invalid_project"), "message": .string(errors.map(\.message).joined(separator: " "))])]))
                exit(ExitCode.rejected.rawValue)
            }
            return report

        case "import":
            let session = try open(try arguments.require(1, "the project path"))
            let files = arguments.positionals.dropFirst(2).map(fileURL)
            guard !files.isEmpty else { throw CLIError(code: .usage, identifier: "usage", message: "Name at least one file or folder to import.") }
            let result = try await session.importFiles(Array(files), actor: .cli)
            try session.save()
            return .object(["imported": .array(result.assets.map(Inspection.asset)),
                            "failed": .array(result.failures.map { .object(["file": .string($0.fileName), "reason": .string($0.reason)]) })])

        case "apply":
            return try apply(arguments)

        case "collect":
            let session = try open(try arguments.require(1, "the project path"))
            let report = try session.collectMedia()
            return .object(["copied": .int(report.copied), "alreadyInside": .int(report.alreadyInside), "deduplicated": .int(report.deduplicated),
                            "missing": .array(report.missing.map { .string($0) }), "bytesCopied": .int(Int(report.bytesCopied))])

        case "snapshot":
            return try snapshot(arguments)

        case "storage":
            let session = try open(try arguments.require(1, "the project path"))
            var freed: Int64 = 0
            if arguments.flags.contains("purge") { freed = session.package.purgeCaches() }
            let usage = session.package.storageUsage()
            return .object(["media": .int(Int(usage.media)), "proxies": .int(Int(usage.proxies)), "thumbnails": .int(Int(usage.thumbnails)),
                            "waveforms": .int(Int(usage.waveforms)), "cache": .int(Int(usage.cache)), "snapshots": .int(Int(usage.snapshots)),
                            "exports": .int(Int(usage.exports)), "purgeable": .int(Int(usage.purgeable)), "freed": .int(Int(freed))])

        case "probe":
            let url = fileURL(try arguments.require(1, "the file path"))
            let (kind, metadata) = try await MediaProbe.probe(url)
            return .object(["kind": .string(kind.rawValue), "metadata": .encoding(metadata), "durationSeconds": .double(metadata.duration.seconds)])

        case "beats":
            return try await beats(arguments)

        case "captions":
            return try captions(arguments)

        case "presets":
            return .array(ExportPreset.builtIn.map { .encoding($0) })

        case "export":
            return try await export(arguments)

        case "comic":
            return try await comic(arguments)

        case "demo":
            let directory = fileURL(try arguments.require(1, "the directory to build the demo in"))
            let demo = try await DemoBuilder.build(in: directory)
            return .object(["project": .string(demo.projectURL.path), "media": .string(demo.mediaFolder.path),
                            "timelines": .array(demo.sequences.map { .string($0) })])

        case "mcp":
            let session = try open(try arguments.require(1, "the project path"))
            await MCPServer(session: session).run()
            exit(ExitCode.success.rawValue)

        default:
            throw CLIError(code: .usage, identifier: "usage", message: "Unknown command “\(command)”. Run `kirie help`.")
        }
    }

    // MARK: Commands

    static func decodeCommands(_ arguments: Arguments) throws -> [EditCommand] {
        let data: Data
        if let inline = arguments.options["command"] {
            data = Data(inline.utf8)
        } else if let path = arguments.options["file"] {
            guard let contents = FileManager.default.contents(atPath: fileURL(path).path) else {
                throw CLIError(code: .notFound, identifier: "not_found", message: "The command file was not found.")
            }
            guard contents.count <= 16 * 1024 * 1024 else { throw CLIError(code: .rejected, identifier: "rejected", message: "The command file is larger than 16 MB.") }
            data = contents
        } else {
            throw CLIError(code: .usage, identifier: "usage", message: "Pass --command '<json>' or --file <path>.")
        }
        let decoder = ProjectCodec.makeDecoder()
        if let many = try? decoder.decode([EditCommand].self, from: data) { return many }
        return [try decoder.decode(EditCommand.self, from: data)]
    }

    static func apply(_ arguments: Arguments) throws -> JSONValue {
        let session = try open(try arguments.require(1, "the project path"))
        let commands = try decodeCommands(arguments)
        guard !commands.isEmpty, commands.count <= 5_000 else { throw CLIError(code: .rejected, identifier: "rejected", message: "Send between 1 and 5,000 commands.") }
        let destructive = commands.filter(Inspection.isDestructive)
        if !destructive.isEmpty, !arguments.flags.contains("confirm"), !arguments.flags.contains("dry-run") {
            throw CLIError(code: .rejected, identifier: "confirmation_required",
                           message: "These commands remove content (\(destructive.map(\.name).joined(separator: ", "))). Re-run with --confirm.")
        }
        if arguments.flags.contains("dry-run") {
            let patch = try session.engine.dryRun(commands)
            return .object(["dryRun": .bool(true), "wouldChange": .array(patch.events.map { .string(String(describing: $0)) }), "commands": .int(commands.count)])
        }
        let outcome = try session.execute(commands, label: commands.count == 1 ? "CLI edit" : "CLI edit (\(commands.count) commands)", actor: .cli)
        try session.save()
        return .object(["applied": .int(commands.count), "label": .string(outcome.entry.label), "commandID": .string(outcome.entry.id.uuidString),
                        "duration": .double(session.project.activeSequence.duration.seconds)])
    }

    static func snapshot(_ arguments: Arguments) throws -> JSONValue {
        let session = try open(try arguments.require(1, "the project path"))
        let action = try arguments.require(2, "create, list or restore")
        func describe(_ snapshot: SnapshotInfo) -> JSONValue {
            .object(["fileName": .string(snapshot.fileName), "name": .string(snapshot.name), "createdAt": .encoding(snapshot.createdAt),
                     "automatic": .bool(snapshot.automatic)])
        }
        switch action {
        case "create":
            return describe(try session.createSnapshot(name: arguments.positionals.count > 3 ? arguments.positionals[3] : "Snapshot"))
        case "list":
            return .array(session.package.listSnapshots().map(describe))
        case "restore":
            let wanted = try arguments.require(3, "the snapshot file name")
            guard let snapshot = session.package.listSnapshots().first(where: { $0.fileName == wanted || $0.name == wanted }) else {
                throw CLIError(code: .notFound, identifier: "not_found", message: "No snapshot named “\(wanted)”.")
            }
            try session.restoreSnapshot(snapshot)
            return .object(["restored": describe(snapshot), "project": .string(session.project.name)])
        default:
            throw CLIError(code: .usage, identifier: "usage", message: "Use create, list or restore.")
        }
    }

    static func beats(_ arguments: Arguments) async throws -> JSONValue {
        let target = fileURL(try arguments.require(1, "an audio file or project"))
        if target.pathExtension == ProjectPackage.fileExtension {
            let session = try open(target.path)
            guard let raw = arguments.options["clip"], let clipID = UUID(uuidString: raw) else {
                throw CLIError(code: .usage, identifier: "usage", message: "Pass --clip <clip id> (see `kirie timeline`).")
            }
            let (command, analysis) = try await session.beatMarkersCommand(forClip: clipID)
            try session.execute(command, actor: .cli)
            try session.save()
            return .object(["bpm": .double(analysis.bpm), "confidence": .double(analysis.confidence),
                            "markersAdded": .int(session.project.activeSequence.beatTimes.count)])
        }
        let analysis = try await BeatDetector.analyse(target)
        return .object(["bpm": .double(analysis.bpm), "confidence": .double(analysis.confidence), "beats": .array(analysis.beats.map { .double($0) }),
                        "downbeats": .array(analysis.downbeats.map { .int($0) }), "downbeatConfidence": .double(analysis.downbeatConfidence)])
    }

    static func captions(_ arguments: Arguments) throws -> JSONValue {
        let session = try open(try arguments.require(1, "the project path"))
        switch try arguments.require(2, "import or export") {
        case "import":
            let file = fileURL(try arguments.require(3, "the caption file"))
            try session.execute(try session.captionsCommand(fromSubtitleFile: file), actor: .cli)
            try session.save()
            return .object(["captions": .int(ProjectSession.captionSegments(in: session.project.activeSequence).count)])
        case "export":
            guard let format = SubtitleFormat(fileExtension: arguments.options["format"] ?? "srt") else {
                throw CLIError(code: .usage, identifier: "usage", message: "--format must be srt, vtt or lrc.")
            }
            let text = session.exportCaptions(format: format)
            if let out = arguments.options["out"] {
                try text.write(to: fileURL(out), atomically: true, encoding: .utf8)
                return .object(["written": .string(fileURL(out).path), "captions": .int(ProjectSession.captionSegments(in: session.project.activeSequence).count)])
            }
            return .object(["format": .string(format.rawValue), "text": .string(text)])
        default:
            throw CLIError(code: .usage, identifier: "usage", message: "Use import or export.")
        }
    }

    static func export(_ arguments: Arguments) async throws -> JSONValue {
        let session = try open(try arguments.require(1, "the project path"))
        let target = try sequence(session, arguments.options["sequence"])
        var preset = ExportPreset.matching(session.project.canvas)
        if let id = arguments.options["preset"] {
            guard let named = ExportPreset.named(id) else {
                throw CLIError(code: .usage, identifier: "usage", message: "Unknown preset “\(id)”. Run `kirie presets`.")
            }
            preset = named
        }
        var range: TimeRange?
        let from = try arguments.double("from"), to = try arguments.double("to")
        if from != nil || to != nil {
            let start = RationalTime(seconds: max(0, from ?? 0)).rounded(toFrame: preset.frameRate)
            let end = RationalTime(seconds: to ?? target.duration.seconds).rounded(toFrame: preset.frameRate)
            guard end > start else { throw CLIError(code: .usage, identifier: "usage", message: "--to must be after --from.") }
            range = TimeRange(start: start, end: end)
        }
        let destination = arguments.options["out"].map(fileURL) ?? session.defaultExportURL(preset: preset, name: "\(session.project.name) – \(target.name)")
        let options = RenderOptions(reduceMotion: arguments.flags.contains("reduce-motion"), silent: arguments.flags.contains("silent"))

        // Ctrl-C cancels cleanly: the partial file is removed and the exit code is 130.
        let cancellation = ExportCancellation()
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { cancellation.cancel() }
        interrupt.resume()
        defer { interrupt.cancel() }

        let reporter = ProgressReporter()
        let report = try await session.export(preset: preset, to: destination, sequenceID: target.id, range: range, options: options,
                                              cancellation: cancellation) { reporter.report($0) }
        return .encoding(report)
    }

    final class ProgressReporter: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1
        func report(_ value: Double) {
            let percent = Int((value * 100).rounded(.down))
            lock.lock()
            defer { lock.unlock() }
            guard percent >= last + 5 || percent == 100, percent != last else { return }
            last = percent
            CommandLineTool.progress("progress \(percent)")
        }
    }

    static func comic(_ arguments: Arguments) async throws -> JSONValue {
        let action = try arguments.require(1, "a comic command")
        func rect(_ r: UnitRect) -> JSONValue { .object(["x": .double(r.x), "y": .double(r.y), "width": .double(r.width), "height": .double(r.height)]) }
        switch action {
        case "detect":
            var options = PanelDetector.Options()
            options.rightToLeft = arguments.flags.contains("manga") || arguments.flags.contains("right-to-left")
            let detection = try PanelDetector.detect(url: fileURL(try arguments.require(2, "the image path")), options: options)
            return .object(["panels": .array(detection.panels.map(rect)), "paper": .string(detection.paper.hex)])

        case "wireframe":
            guard let count = Int(try arguments.require(2, "the number of panels")), let wireframe = ComicSheets.wireframe(panelCount: count) else {
                throw CLIError(code: .usage, identifier: "usage", message: "Wireframes are available for 2 to 5 panels.")
            }
            guard let out = arguments.options["out"] else { throw CLIError(code: .usage, identifier: "usage", message: "Pass --out <file.png>.") }
            guard Thumbnailer.write(wireframe.image, to: fileURL(out)) else { throw CLIError(code: .failure, identifier: "error", message: "The wireframe could not be written.") }
            return .object(["written": .string(fileURL(out).path), "panels": .array(wireframe.panels.map(rect)), "description": .string(wireframe.description)])

        default:
            break
        }

        let session = try open(try arguments.require(2, "the project path"))
        switch action {
        case "add-strip":
            let selector = try arguments.require(3, "the image's name or id")
            guard let asset = session.project.assets.first(where: { $0.id.uuidString == selector || $0.name == selector || ($0.name as NSString).deletingPathExtension == selector }) else {
                throw CLIError(code: .notFound, identifier: "not_found", message: "No imported image named “\(selector)”. Import it first.")
            }
            let strip = try session.addStrip(assetID: asset.id, number: arguments.options["number"].flatMap { Int($0) }, slug: arguments.options["slug"],
                                             rightToLeft: arguments.flags.contains("manga") || arguments.flags.contains("right-to-left"))
            try session.save()
            return .object(["stripID": .string(strip.id.uuidString), "panels": .array(strip.panels.map { rect($0.rect) }), "paper": .string(strip.paperColor.hex)])

        case "status":
            return Inspection.qa(session)

        case "review":
            let target = try strip(session, arguments.options["strip"])
            guard let number = arguments.options["panel"].flatMap({ Int($0) }), number >= 1, number <= target.panels.count else {
                throw CLIError(code: .usage, identifier: "usage", message: "--panel must be between 1 and \(target.panels.count).")
            }
            let review = PanelReview(status: try status(arguments.options["status"]), strangerNote: arguments.options["note"] ?? target.panels[number - 1].review.strangerNote)
            try session.execute(.comic(command: .setPanelReview(stripID: target.id, panelID: target.panels[number - 1].id, review: review)), actor: .cli)
            try session.save()
            return Inspection.qa(session)

        case "check":
            let target = try strip(session, arguments.options["strip"])
            guard let item = arguments.options["item"] else { throw CLIError(code: .usage, identifier: "usage", message: "Pass --item <id>, for example --item A.") }
            try session.execute(.comic(command: .setCheck(stripID: target.id, itemID: item.uppercased(),
                                                 result: CheckResult(status: try status(arguments.options["status"]), reason: arguments.options["reason"] ?? ""))), actor: .cli)
            try session.save()
            return Inspection.qa(session)

        case "approve":
            let target = try strip(session, arguments.options["strip"])
            guard let by = arguments.options["by"], !by.isEmpty else { throw CLIError(code: .usage, identifier: "usage", message: "Pass --by <reviewer name>.") }
            try session.approveStrip(stripID: target.id, approvedBy: by)
            try session.save()
            return Inspection.qa(session)

        case "reel":
            let target = try strip(session, arguments.options["strip"])
            let sequence = try session.buildStripReel(stripID: target.id, options: StripReelOptions(varyTransitions: arguments.flags.contains("vary")))
            try session.save()
            return Inspection.timeline(sequence)

        case "contact-sheet":
            let target = try strip(session, arguments.options["strip"])
            guard let out = arguments.options["out"] else { throw CLIError(code: .usage, identifier: "usage", message: "Pass --out <file.png>.") }
            guard Thumbnailer.write(try session.contactSheet(stripID: target.id), to: fileURL(out)) else {
                throw CLIError(code: .failure, identifier: "error", message: "The contact sheet could not be written.")
            }
            return .object(["written": .string(fileURL(out).path), "panels": .int(target.panels.count)])

        case "carousel":
            let target = try strip(session, arguments.options["strip"])
            let urls = try session.exportCarousel(stripID: target.id, to: arguments.options["out"].map(fileURL), includeFullStrip: !arguments.flags.contains("no-full-strip"))
            return .object(["slides": .array(urls.map { .string($0.path) })])

        default:
            throw CLIError(code: .usage, identifier: "usage", message: "Unknown comic command “\(action)”. Run `kirie help`.")
        }
    }
}
