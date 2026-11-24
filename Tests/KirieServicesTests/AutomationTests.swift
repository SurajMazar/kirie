import Foundation
import MediaServices
import ProjectDomain
import Testing
@testable import KirieServices

@Suite("Automation: MCP server", .serialized)
struct MCPTests {
    static func server() async throws -> (MCPServer, ProjectSession, URL) {
        let root = try scenarioFolder("mcp\(UUID().uuidString.prefix(4))")
        let session = try ProjectSession.create(at: root.appendingPathComponent("Agent"), name: "Agent project", canvas: CanvasSettings(width: 1080, height: 1920))
        let still = root.appendingPathComponent("photo.png")
        try SampleMedia.writeStill(to: still, color: .paper, label: "")
        try await session.importFiles([still])
        try session.save()
        return (MCPServer(session: session, clientName: "test-agent"), session, root)
    }

    static func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any] = [:], id: Int = 1) async -> (text: String, isError: Bool) {
        let reply = await server.handle(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        let content = reply?["result"]?["content"]
        guard case .array(let items)? = content, let text = items.first?["text"]?.stringValue else { return ("", true) }
        return (text, reply?["result"]?["isError"]?.boolValue ?? true)
    }

    @Test func handshakeAndToolListing() async throws {
        let (server, _, root) = try await Self.server()
        defer { try? FileManager.default.removeItem(at: root) }
        let hello = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect(hello?["result"]?["serverInfo"]?["name"]?.stringValue == "kirie")
        #expect(hello?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil, "notifications get no reply")
        let list = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        guard case .array(let tools)? = list?["result"]?["tools"] else { Issue.record("no tools"); return }
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names == ["project_info", "timeline", "qa_status", "command_reference", "apply_commands", "undo", "build_strip_reel", "export"])
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"]?.stringValue == "object" })
        let unknown = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        #expect(unknown?["error"]?["code"] == .int(-32601))
        let badTool = await server.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "run_shell", "arguments": ["cmd": "rm -rf /"]]])
        #expect(badTool?["error"]?["code"] == .int(-32602), "there is no shell tool")
    }

    @Test func agentsEditThroughTheSameValidatedCommands() async throws {
        let (server, session, root) = try await Self.server()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = try #require(session.project.assets.first)
        let info = await Self.call(server, "project_info")
        #expect(!info.isError && info.text.contains("Agent project") && info.text.contains("reels-h264"))

        let clip = UUID()
        let add: [String: Any] = ["addClip": ["clipID": clip.uuidString, "assetID": asset.id.uuidString]]
        // Dry run validates without changing anything.
        let dry = await Self.call(server, "apply_commands", ["commands": [add], "dry_run": true])
        #expect(!dry.isError && dry.text.contains("\"valid\" : true"))
        #expect(session.project.activeSequence.allClips.isEmpty)

        let applied = await Self.call(server, "apply_commands", ["commands": [add, ["trimClip": ["clipID": clip.uuidString, "edge": "end", "to": "5/1"]]]])
        #expect(!applied.isError, "\(applied.text)")
        #expect(session.project.activeSequence.clip(clip)?.duration == RationalTime(5, 1))
        #expect(session.engine.undoStack.last?.envelope.actor == .mcp(client: "test-agent"), "the edit is attributed to the agent")
        #expect(!session.hasUnsavedChanges, "agent edits are saved")

        // Invalid edits are rejected with the engine's own message and change nothing.
        let invalid = await Self.call(server, "apply_commands", ["commands": [["setSpeed": ["clipID": clip.uuidString, "speed": 5000]]]])
        #expect(invalid.isError && invalid.text.contains("Speed"))
        let malformed = await Self.call(server, "apply_commands", ["commands": [["launchMissiles": [:]]]])
        #expect(malformed.isError && malformed.text.contains("command_reference"))

        // Deleting needs explicit confirmation.
        let remove: [String: Any] = ["removeClips": ["clipIDs": [clip.uuidString], "ripple": true]]
        let refused = await Self.call(server, "apply_commands", ["commands": [remove]])
        #expect(refused.isError && refused.text.contains("confirm_destructive"))
        #expect(session.project.activeSequence.clip(clip) != nil)
        let confirmed = await Self.call(server, "apply_commands", ["commands": [remove], "confirm_destructive": true])
        #expect(!confirmed.isError)
        #expect(session.project.activeSequence.allClips.isEmpty)

        // One undo restores the clip.
        let undone = await Self.call(server, "undo")
        #expect(!undone.isError && session.project.activeSequence.clip(clip) != nil)
        let timeline = await Self.call(server, "timeline")
        #expect(timeline.text.contains(clip.uuidString))
    }

    @Test func exportsNeedConfirmationAndStayInsideTheProject() async throws {
        let (server, session, root) = try await Self.server()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = try #require(session.project.assets.first)
        try session.execute(.addClip(sequenceID: nil, clipID: UUID(), assetID: asset.id, trackID: nil, start: nil, sourceStart: nil,
                                     duration: RationalTime(1, 1), index: nil))
        let refused = await Self.call(server, "export", ["confirm": false])
        #expect(refused.isError && refused.text.contains("confirm: true"))
        // A path-traversal file name is reduced to its last component inside Exports/.
        let exported = await Self.call(server, "export", ["confirm": true, "preset": "square", "file_name": "../../../../tmp/escape.mp4"])
        #expect(!exported.isError, "\(exported.text)")
        #expect(FileManager.default.fileExists(atPath: session.package.exportsURL.appendingPathComponent("escape.mp4").path))
        #expect(exported.text.contains("\"passed\" : true"))
        let reference = await Self.call(server, "command_reference")
        #expect(reference.text.contains("splitClip") && reference.text.contains("value/timescale"))
        let qa = await Self.call(server, "qa_status")
        #expect(qa.text.contains("\"enabled\" : false"))
    }
}
