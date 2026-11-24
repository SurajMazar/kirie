import Foundation
import ProjectDomain

/// A small JSON tree for machine-readable output from the CLI and MCP server.
public enum JSONValue: Encodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value.isFinite ? value : 0)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Wraps any Encodable value (for example a project or a report) as a JSON tree.
    public static func encoding<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? ProjectCodec.makeEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return from(object)
    }

    public static func from(_ object: Any) -> JSONValue {
        switch object {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15 ? .int(number.intValue) : .double(double)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map(from))
        case let dictionary as [String: Any]: return .object(dictionary.mapValues(from))
        default: return .null
        }
    }

    public func serialised(pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
}

/// Read-only summaries shared by the CLI and MCP server.
public enum Inspection {
    public static func project(_ session: ProjectSession) -> JSONValue {
        let project = session.project
        let lock = session.exportLock()
        return .object([
            "id": .string(project.id.uuidString), "name": .string(project.name), "path": .string(session.package.url.path),
            "schemaVersion": .int(project.schemaVersion),
            "canvas": .object(["width": .int(project.canvas.width), "height": .int(project.canvas.height),
                               "frameRate": .double(project.canvas.frameRate.fps), "colorSpace": .string(project.canvas.colorSpace.rawValue)]),
            "modifiedAt": .encoding(project.modifiedAt),
            "assets": .array(project.assets.map(asset)),
            "missingMedia": .array(session.package.missingAssets(in: project).map { .string($0.name) }),
            "sequences": .array(project.sequences.map { sequence in
                .object(["id": .string(sequence.id.uuidString), "name": .string(sequence.name), "active": .bool(sequence.id == project.activeSequenceID),
                         "duration": .double(sequence.duration.seconds), "tracks": .int(sequence.tracks.count), "clips": .int(sequence.allClips.count),
                         "markers": .int(sequence.markers.count)])
            }),
            "comic": project.comic.map { comic in
                .object(["folderName": .string(comic.folderName), "strips": .int(comic.strips.count), "requireQAForExport": .bool(comic.requireQAForExport)])
            } ?? .null,
            "exportLock": exportLock(lock),
            "exportPreset": .string(project.exportPresetID),
        ])
    }

    public static func asset(_ asset: MediaAsset) -> JSONValue {
        .object(["id": .string(asset.id.uuidString), "name": .string(asset.name), "kind": .string(asset.kind.rawValue),
                 "duration": .double(asset.metadata.duration.seconds), "width": .int(asset.metadata.displayWidth), "height": .int(asset.metadata.displayHeight),
                 "hasAudio": .bool(asset.metadata.hasAudio), "rights": .string(asset.rights.status.rawValue), "path": .string(asset.reference.absolutePath)])
    }

    public static func timeline(_ sequence: Sequence) -> JSONValue {
        .object([
            "id": .string(sequence.id.uuidString), "name": .string(sequence.name), "duration": .double(sequence.duration.seconds),
            "tracks": .array(sequence.tracks.map { track in
                .object(["id": .string(track.id.uuidString), "kind": .string(track.kind.rawValue), "name": .string(track.name),
                         "muted": .bool(track.muted), "hidden": .bool(track.hidden), "locked": .bool(track.locked),
                         "clips": .array(track.clips.map { clip in
                             .object(["id": .string(clip.id.uuidString), "kind": .string(clip.kind.rawValue), "name": .string(clip.name),
                                      "start": .double(clip.start.seconds), "duration": .double(clip.duration.seconds),
                                      "sourceStart": .double(clip.sourceStart.seconds), "speed": .double(clip.speed),
                                      "assetID": clip.assetID.map { .string($0.uuidString) } ?? .null,
                                      "transition": clip.transitionIn.map { .string($0.type.rawValue) } ?? .null,
                                      "text": clip.text.map { .string($0.string) } ?? .null])
                         })])
            }),
            "markers": .array(sequence.markers.map { .object(["id": .string($0.id.uuidString), "time": .double($0.time.seconds), "kind": .string($0.kind.rawValue)]) }),
        ])
    }

    public static func exportLock(_ lock: ExportLockStatus) -> JSONValue {
        .object(["locked": .bool(lock.isLocked),
                 "strips": .array(lock.strips.map { .object(["stripID": .string($0.stripID.uuidString), "state": .string($0.state.rawValue), "message": .string($0.message)]) })])
    }

    public static func qa(_ session: ProjectSession) -> JSONValue {
        guard let comic = session.project.comic else { return .object(["enabled": .bool(false)]) }
        return .object([
            "enabled": .bool(true), "requireQAForExport": .bool(comic.requireQAForExport), "exportLock": exportLock(session.exportLock()),
            "strips": .array(comic.strips.map { strip in
                .object(["id": .string(strip.id.uuidString), "image": .string(session.project.asset(strip.assetID)?.name ?? ""),
                         "panels": .array(strip.panels.enumerated().map { index, panel in
                             .object(["index": .int(index + 1), "id": .string(panel.id.uuidString), "status": .string(panel.review.status.rawValue),
                                      "note": .string(panel.review.strangerNote),
                                      "rect": .object(["x": .double(panel.rect.x), "y": .double(panel.rect.y), "width": .double(panel.rect.width), "height": .double(panel.rect.height)])])
                         }),
                         "checks": .object(Dictionary(uniqueKeysWithValues: comic.checklist.items.map { item in
                             (item.id, JSONValue.object(["title": .string(item.title), "status": .string((strip.checks[item.id] ?? CheckResult()).status.rawValue),
                                                         "reason": .string((strip.checks[item.id] ?? CheckResult()).reason)]))
                         })),
                         "blockers": .array(QAGate.approvalBlockers(strip: strip, comic: comic).map { .string($0) }),
                         "approved": .bool(strip.approval != nil), "rejectedAttempts": .int(strip.rejected.count)])
            }),
        ])
    }

    /// Commands that remove user content and so need explicit confirmation from automation clients.
    public static func isDestructive(_ command: EditCommand) -> Bool {
        switch command {
        case .removeAsset, .removeSequence, .removeTrack, .removeClips, .removeMarkers, .replaceSequence: return true
        case .comic(let comic):
            switch comic {
            case .removeStrip, .revokeApproval, .setRequireQA: return true
            default: return false
            }
        default: return false
        }
    }
}
