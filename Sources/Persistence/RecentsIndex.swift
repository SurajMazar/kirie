import Foundation
import ProjectDomain
import SQLite3

public struct IndexedProject: Sendable, Equatable, Identifiable {
    public var path: String
    public var projectID: String
    public var name: String
    public var modifiedAt: Date
    public var openedAt: Date
    public var width: Int
    public var height: Int
    public var duration: Double
    public var isComic: Bool
    public var archived: Bool
    public var folder: String

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// SQLite index of known projects for the project hub and search.
///
/// This is only a cache. Project packages stay authoritative: delete the database and it is rebuilt
/// by `rebuild(scanning:)`. All statements use bound parameters.
public final class RecentsIndex: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Kirie", isDirectory: true).appendingPathComponent("index.sqlite")
    }

    public init(url: URL = RecentsIndex.defaultURL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            database = nil
            throw PersistenceError.indexFailed(message)
        }
        try run("""
        CREATE TABLE IF NOT EXISTS projects (
            path TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, modified REAL NOT NULL,
            opened REAL NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, duration REAL NOT NULL,
            is_comic INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0, folder TEXT NOT NULL DEFAULT ''
        )
        """, bind: [])
    }

    deinit {
        sqlite3_close(database)
    }

    private enum Value {
        case text(String), real(Double), int(Int)
    }

    private func prepare(_ sql: String, bind values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PersistenceError.indexFailed(String(cString: sqlite3_errmsg(database)))
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, RecentsIndex.transient)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .int(let number): sqlite3_bind_int64(statement, index, Int64(number))
            }
        }
        return statement
    }

    private func run(_ sql: String, bind values: [Value]) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bind: values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistenceError.indexFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// Records a project as known and just opened.
    public func record(_ project: Project, at url: URL, opened: Date = Date()) throws {
        try run("""
        INSERT INTO projects (path, project_id, name, modified, opened, width, height, duration, is_comic)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET project_id = excluded.project_id, name = excluded.name,
            modified = excluded.modified, opened = excluded.opened, width = excluded.width,
            height = excluded.height, duration = excluded.duration, is_comic = excluded.is_comic
        """, bind: [.text(url.standardizedFileURL.path), .text(project.id.uuidString), .text(project.name),
                    .real(project.modifiedAt.timeIntervalSince1970), .real(opened.timeIntervalSince1970),
                    .int(project.canvas.width), .int(project.canvas.height), .real(project.activeSequence.duration.seconds),
                    .int(project.comic == nil ? 0 : 1)])
    }

    public func setArchived(_ archived: Bool, path: String) throws {
        try run("UPDATE projects SET archived = ? WHERE path = ?", bind: [.int(archived ? 1 : 0), .text(path)])
    }

    public func setFolder(_ folder: String, path: String) throws {
        try run("UPDATE projects SET folder = ? WHERE path = ?", bind: [.text(String(folder.prefix(80))), .text(path)])
    }

    public func remove(path: String) throws {
        try run("DELETE FROM projects WHERE path = ?", bind: [.text(path)])
    }

    /// Most recently opened first. `search` matches the project name.
    public func list(search: String = "", includeArchived: Bool = false) throws -> [IndexedProject] {
        lock.lock()
        defer { lock.unlock() }
        var sql = "SELECT path, project_id, name, modified, opened, width, height, duration, is_comic, archived, folder FROM projects WHERE 1 = 1"
        var values: [Value] = []
        if !includeArchived { sql += " AND archived = 0" }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            sql += " AND name LIKE ? ESCAPE '\\'"
            let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            values.append(.text("%\(escaped)%"))
        }
        sql += " ORDER BY opened DESC LIMIT 500"
        let statement = try prepare(sql, bind: values)
        defer { sqlite3_finalize(statement) }
        var rows: [IndexedProject] = []
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(IndexedProject(
                path: text(0), projectID: text(1), name: text(2),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                openedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                width: Int(sqlite3_column_int64(statement, 5)), height: Int(sqlite3_column_int64(statement, 6)),
                duration: sqlite3_column_double(statement, 7), isComic: sqlite3_column_int64(statement, 8) != 0,
                archived: sqlite3_column_int64(statement, 9) != 0, folder: text(10)))
        }
        return rows
    }

    /// Drops entries whose package no longer exists. Returns how many were removed.
    @discardableResult
    public func pruneMissing() throws -> Int {
        let missing = try list(includeArchived: true).filter { !$0.exists }
        for entry in missing { try remove(path: entry.path) }
        return missing.count
    }

    /// Rebuilds the index from packages found directly inside the given folders.
    @discardableResult
    public func rebuild(scanning directories: [URL]) throws -> Int {
        var found = 0
        for directory in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix("." + ProjectPackage.fileExtension) {
                let url = directory.appendingPathComponent(name)
                guard let opened = try? ProjectPackage.open(url) else { continue }
                try record(opened.project, at: url, opened: opened.project.modifiedAt)
                found += 1
            }
        }
        return found
    }
}
