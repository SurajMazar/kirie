import Foundation

public enum ProjectFileError: Error, Equatable, LocalizedError, Sendable {
    case notAProject(String)
    case newerSchema(found: Int, supported: Int)
    case corrupt(String)
    case invalid([String])

    public var errorDescription: String? {
        switch self {
        case .notAProject(let detail): "This is not a Kirie project. \(detail)"
        case .newerSchema(let found, let supported):
            "This project was saved by a newer version of Kirie (format \(found); this version reads up to \(supported)). Update Kirie to open it."
        case .corrupt(let detail): "The project file is damaged and cannot be read. \(detail)"
        case .invalid(let problems): "The project file has problems: " + problems.joined(separator: " ")
        }
    }
}

extension Date {
    /// Project files keep millisecond precision; rounding here makes save → load exact.
    public var roundedToMilliseconds: Date {
        Date(timeIntervalSince1970: Double(millisecondsSince1970) / 1000)
    }

    var millisecondsSince1970: Int64 {
        let scaled = (timeIntervalSince1970 * 1000).rounded()
        return scaled.isFinite ? Int64(max(min(scaled, 8.0e15), -8.0e15)) : 0
    }
}

/// Deterministic, human-readable serialisation of projects, with schema migration.
public enum ProjectCodec {
    public static let maxBytes = 256 * 1024 * 1024

    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// `2026-11-24T10:46:16.739Z`, built from integer milliseconds so formatting can never drift.
    static func string(from date: Date) -> String {
        let ms = date.millisecondsSince1970
        var secs = ms / 1000
        var fraction = ms % 1000
        if fraction < 0 { fraction += 1000; secs -= 1 }
        let base = Date(timeIntervalSince1970: Double(secs)).formatted(whole)
        return String(base.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    static func date(from text: String) -> Date? {
        guard let dot = text.lastIndex(of: "."), text.hasSuffix("Z") else {
            return (try? whole.parse(text))?.roundedToMilliseconds
        }
        let digits = text[text.index(after: dot)..<text.index(before: text.endIndex)]
        guard !digits.isEmpty, digits.count <= 9, let raw = Int64(digits),
              let base = try? whole.parse(String(text[..<dot]) + "Z") else { return nil }
        var scale: Int64 = 1
        for _ in 0..<digits.count { scale *= 10 }
        let fractionMs = Int64((Double(raw) / Double(scale) * 1000).rounded())
        let ms = Int64(base.timeIntervalSince1970.rounded()) * 1000 + fractionMs
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys + pretty printing = stable, diff-friendly files.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date '\(text)'")
        }
        return decoder
    }

    public static func encode(_ project: Project) throws -> Data {
        var data = try makeEncoder().encode(project)
        data.append(0x0A)
        return data
    }

    /// Decodes, migrating older schemas first. Throws typed errors; never traps on bad input.
    public static func decode(_ data: Data, validate: Bool = true) throws -> Project {
        guard data.count <= maxBytes else { throw ProjectFileError.corrupt("The file is larger than 256 MB.") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProjectFileError.corrupt("It is not valid JSON.")
        }
        guard var json = object as? [String: Any] else { throw ProjectFileError.notAProject("The file does not contain a project object.") }
        let version = (json["schemaVersion"] as? Int) ?? 0
        guard version <= SchemaVersion.current else {
            throw ProjectFileError.newerSchema(found: version, supported: SchemaVersion.current)
        }
        if version < SchemaVersion.current {
            json = try ProjectMigrator.migrate(json, from: version)
        }
        let migrated = version < SchemaVersion.current ? try JSONSerialization.data(withJSONObject: json) : data
        let project: Project
        do {
            project = try makeDecoder().decode(Project.self, from: migrated)
        } catch let error as DecodingError {
            throw ProjectFileError.corrupt(describe(error))
        }
        if validate {
            let problems = ProjectValidator.validate(project).filter { $0.severity == .error }.map(\.message)
            guard problems.isEmpty else { throw ProjectFileError.invalid(problems) }
        }
        return project
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "the top level" : joined
        }
        switch error {
        case .keyNotFound(let key, let context): return "Missing “\(key.stringValue)” at \(path(context))."
        case .typeMismatch(_, let context): return "Unexpected value at \(path(context))."
        case .valueNotFound(_, let context): return "Missing value at \(path(context))."
        case .dataCorrupted(let context): return "Bad value at \(path(context)). \(context.debugDescription)"
        @unknown default: return "Unreadable content."
        }
    }
}

/// Step-by-step schema migrations. Each step upgrades raw JSON from version N to N+1.
public enum ProjectMigrator {
    typealias Step = @Sendable (inout [String: Any]) throws -> Void

    static let steps: [Int: Step] = [
        // 0 → 1: pre-release drafts had no schema version, no export preset and no explicit colour space.
        0: { json in
            if json["exportPresetID"] == nil { json["exportPresetID"] = "custom" }
            if var canvas = json["canvas"] as? [String: Any] {
                if canvas["colorSpace"] == nil { canvas["colorSpace"] = ColorSpaceTag.rec709.rawValue }
                if canvas["background"] == nil { canvas["background"] = ["r": 0, "g": 0, "b": 0, "a": 1] }
                json["canvas"] = canvas
            }
            if json["assets"] == nil { json["assets"] = [Any]() }
        },
    ]

    public static func migrate(_ json: [String: Any], from version: Int) throws -> [String: Any] {
        var current = json
        var at = max(0, version)
        while at < SchemaVersion.current {
            guard let step = steps[at] else {
                throw ProjectFileError.corrupt("No migration from format \(at).")
            }
            try step(&current)
            at += 1
            current["schemaVersion"] = at
        }
        return current
    }
}
