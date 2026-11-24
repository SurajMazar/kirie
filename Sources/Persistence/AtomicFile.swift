import CryptoKit
import Foundation

public enum PersistenceError: Error, Equatable, LocalizedError, Sendable {
    case notAPackage(String)
    case alreadyExists(String)
    case writeFailed(String)
    case readFailed(String)
    case unsafePath(String)
    case snapshotNotFound(String)
    case indexFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAPackage(let path): "“\(path)” is not a Kirie project."
        case .alreadyExists(let path): "“\(path)” already exists. Choose another name or location."
        case .writeFailed(let detail): "Could not save. \(detail)"
        case .readFailed(let detail): "Could not read the project. \(detail)"
        case .unsafePath(let path): "The project refers to a file outside its folder (\(path)), which is not allowed."
        case .snapshotNotFound(let name): "The snapshot “\(name)” no longer exists."
        case .indexFailed(let detail): "The project index could not be updated. \(detail)"
        }
    }
}

/// Crash-safe file writes: data goes to a temporary sibling, is flushed to disk, then renamed over
/// the destination. A reader therefore always sees either the complete old file or the complete
/// new one, even if the process is killed mid-save.
public enum AtomicFile {
    static let temporaryMarker = ".kirie-tmp-"

    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("\(url.lastPathComponent)\(temporaryMarker)\(UUID().uuidString)")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: nil) else {
            throw PersistenceError.writeFailed("Cannot create a file in \(directory.path). Check permissions and free space.")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? manager.removeItem(at: temporary)
            throw PersistenceError.writeFailed(error.localizedDescription)
        }
        if rename(temporary.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(at: temporary)
            throw PersistenceError.writeFailed("Could not replace \(url.lastPathComponent): \(reason).")
        }
    }

    /// Removes temporary files left behind by an interrupted save.
    @discardableResult
    public static func removeLeftovers(in directory: URL) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where name.contains(temporaryMarker) {
            if (try? manager.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}

public enum FileHasher {
    /// Streaming SHA-256 of a whole file, as lowercase hex. Used for QA approvals.
    public static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PersistenceError.readFailed("\(url.lastPathComponent) cannot be opened.")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Fast fingerprint: size plus the first and last megabyte. Good enough to recognise a moved or
    /// renamed file without reading gigabytes.
    public static func fingerprint(of url: URL) throws -> (size: Int64, fingerprint: String) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PersistenceError.readFailed("\(url.lastPathComponent) cannot be opened.")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let window = 1 << 20
        hasher.update(data: try handle.read(upToCount: window) ?? Data())
        if size > Int64(window * 2) {
            try handle.seek(toOffset: UInt64(size - Int64(window)))
            hasher.update(data: try handle.read(upToCount: window) ?? Data())
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
