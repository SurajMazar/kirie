import Foundation
import Persistence
import ProjectDomain
import RenderEngine

/// A Model Context Protocol server over stdio, scoped to one explicitly chosen project.
///
/// Agents get read-only inspection plus the same typed edit commands the app uses. There is no
/// shell, no arbitrary file access and no raw project JSON editing: everything goes through the
/// command engine and its validation. Destructive commands and exports need an explicit confirmation flag.
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"
    public static let maxCommandsPerCall = 500

    private let session: ProjectSession
    private let clientName: String

    public init(session: ProjectSession, clientName: String = "mcp") {
        self.session = session
        self.clientName = clientName
    }

    // MARK: Tool catalogue

    struct Tool {
        var name: String
        var description: String
        var schema: JSONValue
    }

    static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map { .string($0) }),
                 "additionalProperties": .bool(false)])
    }

    static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    static let tools: [Tool] = [
        Tool(name: "project_info", description: "Read-only summary of the open Kirie project: canvas, media, timelines, missing files and export lock.", schema: schema()),
        Tool(name: "timeline", description: "Read-only tracks, clips and markers of a timeline. Use the ids it returns in edit commands.",
             schema: schema(["sequence": property("string", "Timeline name or id. Defaults to the active timeline.")])),
        Tool(name: "qa_status", description: "Read-only Comic Studio QA state: panel reviews, checklist answers, approval blockers and the export lock.", schema: schema()),
        Tool(name: "command_reference", description: "Lists the edit command names with example JSON for the most common ones.", schema: schema()),
        Tool(name: "apply_commands",
             description: "Validates and applies typed edit commands as one undoable step, then saves. Use dry_run to check first. Commands that remove content need confirm_destructive.",
             schema: schema(["commands": .object(["type": .string("array"), "description": .string("Edit commands, each an object with one key naming the command."),
                                                  "items": .object(["type": .string("object")])]),
                             "dry_run": property("boolean", "Validate only; change nothing."),
                             "confirm_destructive": property("boolean", "Must be true to run commands that remove content.")], required: ["commands"])),
        Tool(name: "undo", description: "Undoes the last edit made in this server session, then saves.", schema: schema()),
        Tool(name: "build_strip_reel", description: "Builds the panel-by-panel reel timeline for the project's comic strip and makes it the active timeline.",
             schema: schema(["vary_transitions": property("boolean", "Use a different transition at every cut.")])),
        Tool(name: "export",
             description: "Renders a timeline to a video file inside the project's Exports folder and verifies the result. Blocked while the Comic Studio export lock is engaged.",
             schema: schema(["preset": property("string", "Export preset id (see project_info). Defaults to the preset matching the canvas."),
                             "sequence": property("string", "Timeline name or id. Defaults to the active timeline."),
                             "file_name": property("string", "Output file name without folders. Defaults to the project and timeline name."),
                             "confirm": property("boolean", "Must be true: exporting writes a file and can take a while.")], required: ["confirm"])),
    ]

    static let commandExamples: [(String, String)] = [
        ("addClip", #"{"addClip": {"clipID": "<new uuid>", "assetID": "<asset id>"}}"#),
        ("splitClip", #"{"splitClip": {"clipID": "<clip id>", "at": "3/1", "newClipID": "<new uuid>"}}"#),
        ("trimClip", #"{"trimClip": {"clipID": "<clip id>", "edge": "end", "to": "9/2"}}"#),
        ("moveClip", #"{"moveClip": {"clipID": "<clip id>", "index": 0}}"#),
        ("removeClips", #"{"removeClips": {"clipIDs": ["<clip id>"], "ripple": true}}"#),
        ("setTransition", #"{"setTransition": {"clipID": "<clip id>", "transition": {"type": "dissolve", "duration": "1/2", "direction": "left"}}}"#),
        ("setSpeed", #"{"setSpeed": {"clipID": "<clip id>", "speed": 2}}"#),
        ("cutToBeat", #"{"cutToBeat": {"clipIDs": ["<clip id>", "<clip id>"], "every": 2}}"#),
        ("renameProject", #"{"renameProject": {"name": "New name"}}"#),
        ("comic.setPanelReview", #"{"comic": {"command": {"setPanelReview": {"stripID": "<strip id>", "panelID": "<panel id>", "review": {"status": "PASS", "strangerNote": "What a stranger sees."}}}}}"#),
    ]

    // MARK: Protocol

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(_ message: [String: Any]) async -> JSONValue? {
        let id = message["id"].map(JSONValue.from)
        guard let method = message["method"] as? String else {
            return id.map { error(id: $0, code: -32600, message: "Invalid request") }
        }
        let parameters = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = parameters["protocolVersion"] as? String
            return response(id: id, .object([
                "protocolVersion": .string(requested ?? MCPServer.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("kirie"), "version": .string(ProjectPackage.appVersion)]),
                "instructions": .string("Kirie project “\(session.project.name)”. Read with project_info and timeline, then edit with apply_commands. Every edit is validated and undoable; exports and deletions need explicit confirmation."),
            ]))
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return response(id: id, .object([:]))
        case "tools/list":
            return response(id: id, .object(["tools": .array(MCPServer.tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema])
            })]))
        case "tools/call":
            guard let name = parameters["name"] as? String else { return id.map { error(id: $0, code: -32602, message: "Missing tool name") } }
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            guard MCPServer.tools.contains(where: { $0.name == name }) else {
                return id.map { error(id: $0, code: -32602, message: "Unknown tool: \(name)") }
            }
            do {
                let result = try await call(name, arguments)
                return response(id: id, .object(["content": .array([.object(["type": .string("text"), "text": .string(result.serialised())])]), "isError": .bool(false)]))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return response(id: id, .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)]))
            }
        default:
            return id.map { error(id: $0, code: -32601, message: "Method not found: \(method)") }
        }
    }

    private func response(id: JSONValue?, _ result: JSONValue) -> JSONValue? {
        guard let id else { return nil }
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(code), "message": .string(message)])])
    }

    // MARK: Tools

    private func sequence(_ selector: Any?) throws -> ProjectDomain.Sequence {
        guard let selector = selector as? String, !selector.isEmpty else { return session.project.activeSequence }
        if let id = UUID(uuidString: selector), let found = session.project.sequence(id) { return found }
        if let found = session.project.sequences.first(where: { $0.name.caseInsensitiveCompare(selector) == .orderedSame }) { return found }
        throw ServiceError.notFound("A timeline named “\(selector)”")
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> JSONValue {
        let actor = CommandActor.mcp(client: clientName)
        switch name {
        case "project_info":
            var info = Inspection.project(session)
            if case .object(var dictionary) = info {
                dictionary["exportPresets"] = .array(ExportPreset.builtIn.map { .string($0.id) })
                info = .object(dictionary)
            }
            return info
        case "timeline":
            return Inspection.timeline(try sequence(arguments["sequence"]))
        case "qa_status":
            return Inspection.qa(session)
        case "command_reference":
            let names = ["renameProject", "setCanvas", "setExportPreset", "importAssets", "removeAsset", "updateAssetInfo", "relinkAsset", "addSequence",
                         "replaceSequence", "removeSequence", "setActiveSequence", "renameSequence", "addTrack", "removeTrack", "setTrackState", "addClip",
                         "insertClip", "removeClips", "moveClip", "trimClip", "splitClip", "duplicateClip", "renameClip", "setTransform", "setKeyframe",
                         "removeKeyframe", "clearKeyframes", "setTransition", "setClipAudio", "detachAudio", "setSpeed", "setText", "setLook", "closeGaps",
                         "addMarkers", "removeMarkers", "moveMarker", "replaceBeatMarkers", "cutToBeat", "replaceCaptions", "comic"]
            return .object(["commands": .array(names.map { .string($0) }),
                            "timeFormat": .string("Times are exact rationals written as \"value/timescale\" seconds, for example \"3/2\" = 1.5 s. Plain numbers of seconds are also accepted."),
                            "examples": .object(Dictionary(uniqueKeysWithValues: MCPServer.commandExamples.map { ($0.0, JSONValue.string($0.1)) }))])
        case "apply_commands":
            guard let raw = arguments["commands"] as? [Any], !raw.isEmpty else { throw ServiceError.invalid("Pass at least one command.") }
            guard raw.count <= MCPServer.maxCommandsPerCall else { throw ServiceError.invalid("At most \(MCPServer.maxCommandsPerCall) commands per call.") }
            let data = try JSONSerialization.data(withJSONObject: raw)
            let commands: [EditCommand]
            do {
                commands = try ProjectCodec.makeDecoder().decode([EditCommand].self, from: data)
            } catch {
                throw ServiceError.invalid("A command does not match Kirie's command format. Call command_reference for the shapes. (\(error.localizedDescription))")
            }
            let dryRun = arguments["dry_run"] as? Bool ?? false
            let destructive = commands.filter(Inspection.isDestructive)
            if !destructive.isEmpty, !dryRun, arguments["confirm_destructive"] as? Bool != true {
                throw ServiceError.invalid("These commands remove content (\(destructive.map(\.name).joined(separator: ", "))). Ask the user, then call again with confirm_destructive: true.")
            }
            if dryRun {
                let patch = try session.engine.dryRun(commands)
                return .object(["dryRun": .bool(true), "valid": .bool(true), "wouldChange": .array(patch.events.map { .string(String(describing: $0)) })])
            }
            let outcome = try session.execute(commands, label: "Agent edit (\(commands.count))", actor: actor)
            try session.save()
            return .object(["applied": .int(commands.count), "label": .string(outcome.entry.label), "undoable": .bool(true),
                            "duration": .double(session.project.activeSequence.duration.seconds)])
        case "undo":
            let outcome = try session.engine.undo()
            try session.save()
            return .object(["undone": .string(outcome.entry.label)])
        case "build_strip_reel":
            guard let strip = session.project.comic?.strips.first else { throw ServiceError.invalid("This project has no comic strip.") }
            let built = try session.buildStripReel(stripID: strip.id, options: StripReelOptions(varyTransitions: arguments["vary_transitions"] as? Bool ?? false))
            try session.save()
            return Inspection.timeline(built)
        case "export":
            guard arguments["confirm"] as? Bool == true else {
                throw ServiceError.invalid("Exporting writes a file. Ask the user, then call again with confirm: true.")
            }
            let target = try sequence(arguments["sequence"])
            var preset = ExportPreset.matching(session.project.canvas)
            if let id = arguments["preset"] as? String {
                guard let named = ExportPreset.named(id) else { throw ServiceError.notFound("An export preset named “\(id)”") }
                preset = named
            }
            // Output is confined to the project's Exports folder.
            let requested = (arguments["file_name"] as? String).map { ($0 as NSString).lastPathComponent } ?? "\(session.project.name) – \(target.name)"
            let cleaned = requested.filter { $0 != "/" && $0 != ":" && $0 != "\0" }
            let stem = (cleaned as NSString).deletingPathExtension.isEmpty ? "export" : (cleaned as NSString).deletingPathExtension
            let destination = session.package.exportsURL.appendingPathComponent("\(stem).\(preset.container.fileExtension)")
            let report = try await session.export(preset: preset, to: destination, sequenceID: target.id)
            return .encoding(report)
        default:
            throw ServiceError.notFound("The tool “\(name)”")
        }
    }

    // MARK: Transport

    /// Serves newline-delimited JSON-RPC on stdin/stdout until stdin closes.
    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard line.utf8.count <= 8 * 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                let failure = JSONValue.object(["jsonrpc": .string("2.0"), "id": .null, "error": .object(["code": .int(-32700), "message": .string("Parse error")])])
                FileHandle.standardOutput.write(Data((failure.serialised(pretty: false) + "\n").utf8))
                continue
            }
            if let reply = await handle(object) {
                FileHandle.standardOutput.write(Data((reply.serialised(pretty: false) + "\n").utf8))
            }
        }
    }
}
