import Foundation
import ProjectDomain

/// Summary written next to the project so tools can list projects without parsing the whole file.
public struct ProjectManifest: Codable, Sendable, Equatable {
    public struct AssetEntry: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var kind: MediaKind
        public var relativePath: String?
        public var fileSize: Int64
        public var fingerprint: String
    }

    public var schemaVersion: Int
    public var appVersion: String
    public var projectID: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var canvas: CanvasSettings
    public var duration: RationalTime
    public var assets: [AssetEntry]

    public init(project: Project, appVersion: String) {
        schemaVersion = project.schemaVersion
        self.appVersion = appVersion
        projectID = project.id
        name = project.name
        createdAt = project.createdAt
        modifiedAt = project.modifiedAt
        canvas = project.canvas
        duration = project.activeSequence.duration
        assets = project.assets.map {
            AssetEntry(id: $0.id, name: $0.name, kind: $0.kind, relativePath: $0.reference.relativePath,
                       fileSize: $0.reference.fileSize, fingerprint: $0.reference.fingerprint)
        }
    }
}

public struct SnapshotInfo: Codable, Sendable, Equatable, Identifiable {
    public var fileName: String
    public var name: String
    public var createdAt: Date
    public var automatic: Bool
    public var id: String { fileName }
}

/// How a project came to be opened.
public enum OpenSource: Sendable, Equatable {
    /// `project.json` was read normally.
    case saved
    /// `project.json` was unreadable; the newest good snapshot was used instead.
    case recoveredFromSnapshot(SnapshotInfo, reason: String)
}

public struct OpenedProject: Sendable {
    public var package: ProjectPackage
    public var project: Project
    public var source: OpenSource
    public var missingAssets: [MediaAsset]
    public var removedTemporaryFiles: Int
}

public struct CollectReport: Sendable, Equatable {
    public var copied: Int
    public var alreadyInside: Int
    public var deduplicated: Int
    public var missing: [String]
    public var bytesCopied: Int64
}

public struct StorageUsage: Sendable, Equatable {
    public var media: Int64
    public var proxies: Int64
    public var thumbnails: Int64
    public var waveforms: Int64
    public var cache: Int64
    public var snapshots: Int64
    public var exports: Int64

    /// Space that can be reclaimed without losing work.
    public var purgeable: Int64 { thumbnails + waveforms + cache + proxies }
}

/// A `.kirie` document package on disk. The package is the source of truth; nothing here needs a
/// running database.
///
///     Name.kirie/
///       manifest.json   project.json
///       Media/  Proxies/  Thumbnails/  Waveforms/  Snapshots/  Cache/  ComicStudio/  Exports/
public struct ProjectPackage: Sendable, Equatable {
    public static let fileExtension = "kirie"
    public static let appVersion = "0.1.0"
    static let subdirectories = ["Media", "Proxies", "Thumbnails", "Waveforms", "Snapshots", "Cache", "ComicStudio", "Exports"]
    static let automaticSnapshotsToKeep = 10

    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public var projectURL: URL { url.appendingPathComponent("project.json") }
    public var manifestURL: URL { url.appendingPathComponent("manifest.json") }
    public var mediaURL: URL { url.appendingPathComponent("Media") }
    public var proxiesURL: URL { url.appendingPathComponent("Proxies") }
    public var thumbnailsURL: URL { url.appendingPathComponent("Thumbnails") }
    public var waveformsURL: URL { url.appendingPathComponent("Waveforms") }
    public var snapshotsURL: URL { url.appendingPathComponent("Snapshots") }
    public var cacheURL: URL { url.appendingPathComponent("Cache") }
    public var comicURL: URL { url.appendingPathComponent("ComicStudio") }
    public var exportsURL: URL { url.appendingPathComponent("Exports") }

    // MARK: Create / open / save

    public static func create(at url: URL, project: Project) throws -> ProjectPackage {
        let package = ProjectPackage(url: url)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: package.url.path) else { throw PersistenceError.alreadyExists(package.url.lastPathComponent) }
        do {
            try manager.createDirectory(at: package.url, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.writeFailed(error.localizedDescription)
        }
        try package.ensureLayout()
        try package.save(project)
        return package
    }

    func ensureLayout() throws {
        for name in ProjectPackage.subdirectories {
            do {
                try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
            } catch {
                throw PersistenceError.writeFailed("Cannot create \(name) inside the project: \(error.localizedDescription)")
            }
        }
    }

    /// Writes the project and its manifest. Each file is replaced atomically, so an interrupted save
    /// never leaves a half-written project.
    public func save(_ project: Project) throws {
        let data: Data
        do {
            data = try ProjectCodec.encode(project)
        } catch {
            throw PersistenceError.writeFailed("The project could not be encoded: \(error.localizedDescription)")
        }
        try AtomicFile.write(data, to: projectURL)
        let manifest = ProjectManifest(project: project, appVersion: ProjectPackage.appVersion)
        var manifestData = (try? ProjectCodec.makeEncoder().encode(manifest)) ?? Data("{}".utf8)
        manifestData.append(0x0A)
        try AtomicFile.write(manifestData, to: manifestURL)
    }

    /// Opens a package. If `project.json` is damaged, falls back to the newest readable snapshot
    /// and says so in `source`.
    public static func open(_ url: URL) throws -> OpenedProject {
        let package = ProjectPackage(url: url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: package.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PersistenceError.notAPackage(url.lastPathComponent)
        }
        let removed = AtomicFile.removeLeftovers(in: package.url)
        try? package.ensureLayout()

        let primary: Result<Project, Error> = Result {
            guard let data = FileManager.default.contents(atPath: package.projectURL.path) else {
                throw PersistenceError.notAPackage(url.lastPathComponent)
            }
            return try ProjectCodec.decode(data)
        }
        switch primary {
        case .success(let project):
            return OpenedProject(package: package, project: project, source: .saved,
                                 missingAssets: package.missingAssets(in: project), removedTemporaryFiles: removed)
        case .failure(let error):
            // A newer-format file is not damage: never replace it with an older snapshot.
            if let fileError = error as? ProjectFileError, case .newerSchema = fileError { throw fileError }
            for snapshot in package.listSnapshots() {
                if let project = try? package.loadSnapshot(snapshot) {
                    let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    return OpenedProject(package: package, project: project,
                                         source: .recoveredFromSnapshot(snapshot, reason: reason),
                                         missingAssets: package.missingAssets(in: project), removedTemporaryFiles: removed)
                }
            }
            throw error
        }
    }

    public func readManifest() -> ProjectManifest? {
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else { return nil }
        return try? ProjectCodec.makeDecoder().decode(ProjectManifest.self, from: data)
    }

    // MARK: Snapshots

    private static func snapshotStamp(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return String(format: "%014lld", ms)
    }

    private static func sanitised(_ name: String) -> String {
        let allowed = name.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" ? $0 : "_" }
        let trimmed = String(allowed).trimmingCharacters(in: .whitespaces)
        return String((trimmed.isEmpty ? "Snapshot" : trimmed).prefix(60))
    }

    /// Saves a restorable copy of the project. Automatic snapshots are pruned to the newest ten.
    @discardableResult
    public func createSnapshot(_ project: Project, name: String, automatic: Bool = false, date: Date = Date()) throws -> SnapshotInfo {
        let label = ProjectPackage.sanitised(name)
        let fileName = "\(ProjectPackage.snapshotStamp(date))-\(automatic ? "auto" : "user")-\(label).json"
        let data = try ProjectCodec.encode(project)
        try? FileManager.default.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        try AtomicFile.write(data, to: snapshotsURL.appendingPathComponent(fileName))
        if automatic {
            let autos = listSnapshots().filter(\.automatic)
            for old in autos.dropFirst(ProjectPackage.automaticSnapshotsToKeep) {
                try? FileManager.default.removeItem(at: snapshotsURL.appendingPathComponent(old.fileName))
            }
        }
        return SnapshotInfo(fileName: fileName, name: label, createdAt: date.roundedToMilliseconds, automatic: automatic)
    }

    /// Newest first.
    public func listSnapshots() -> [SnapshotInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshotsURL.path) else { return [] }
        var snapshots: [SnapshotInfo] = []
        for fileName in names where fileName.hasSuffix(".json") && !fileName.contains(".kirie-tmp-") {
            let parts = fileName.dropLast(5).split(separator: "-", maxSplits: 2).map(String.init)
            guard parts.count == 3, let ms = Int64(parts[0]) else { continue }
            snapshots.append(SnapshotInfo(fileName: fileName, name: parts[2],
                                          createdAt: Date(timeIntervalSince1970: Double(ms) / 1000), automatic: parts[1] == "auto"))
        }
        return snapshots.sorted { $0.fileName > $1.fileName }
    }

    public func loadSnapshot(_ snapshot: SnapshotInfo) throws -> Project {
        let file = snapshotsURL.appendingPathComponent(snapshot.fileName)
        guard file.deletingLastPathComponent().standardizedFileURL == snapshotsURL.standardizedFileURL,
              let data = FileManager.default.contents(atPath: file.path) else {
            throw PersistenceError.snapshotNotFound(snapshot.name)
        }
        return try ProjectCodec.decode(data)
    }

    public func deleteSnapshot(_ snapshot: SnapshotInfo) throws {
        let file = snapshotsURL.appendingPathComponent(snapshot.fileName)
        guard file.deletingLastPathComponent().standardizedFileURL == snapshotsURL.standardizedFileURL else {
            throw PersistenceError.unsafePath(snapshot.fileName)
        }
        try FileManager.default.removeItem(at: file)
    }

    // MARK: Media resolution

    /// File URL for a media reference. A copy inside the package wins, so a collected project keeps
    /// working after it is moved; relative paths can never point outside the package.
    public func resolve(_ reference: MediaReference) -> URL? {
        let manager = FileManager.default
        if let relative = reference.relativePath, !relative.isEmpty {
            let candidate = url.appendingPathComponent(relative).standardizedFileURL
            if candidate.path.hasPrefix(url.path + "/"), manager.fileExists(atPath: candidate.path) { return candidate }
        }
        if !reference.absolutePath.isEmpty, manager.fileExists(atPath: reference.absolutePath) {
            return URL(fileURLWithPath: reference.absolutePath)
        }
        return nil
    }

    public func missingAssets(in project: Project) -> [MediaAsset] {
        project.assets.filter { resolve($0.reference) == nil }
    }

    // MARK: Collect

    /// Bytes that `collect` would copy into the package.
    public func collectEstimate(for project: Project) -> Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for asset in project.assets {
            guard let source = resolve(asset.reference), !source.path.hasPrefix(mediaURL.path + "/") else { continue }
            let key = asset.reference.fingerprint.isEmpty ? source.path : asset.reference.fingerprint
            if seen.insert(key).inserted { total += asset.reference.fileSize }
        }
        return total
    }

    /// Copies every referenced file into `Media/` and returns the references to store, so the
    /// package becomes self-contained. Identical files are copied once.
    public func collect(_ project: Project) throws -> (references: [UUID: MediaReference], report: CollectReport) {
        let manager = FileManager.default
        try ensureLayout()
        var report = CollectReport(copied: 0, alreadyInside: 0, deduplicated: 0, missing: [], bytesCopied: 0)
        var references: [UUID: MediaReference] = [:]
        var placed: [String: String] = [:]
        for asset in project.assets {
            guard let source = resolve(asset.reference) else {
                report.missing.append(asset.name)
                continue
            }
            if source.path.hasPrefix(mediaURL.path + "/") {
                var reference = asset.reference
                reference.relativePath = "Media/" + source.lastPathComponent
                references[asset.id] = reference
                report.alreadyInside += 1
                continue
            }
            let key = asset.reference.fingerprint.isEmpty ? source.path : asset.reference.fingerprint
            if let existing = placed[key] {
                var reference = asset.reference
                reference.relativePath = existing
                references[asset.id] = reference
                report.deduplicated += 1
                continue
            }
            // Unique name inside Media/.
            let base = (source.lastPathComponent as NSString).deletingPathExtension
            let ext = source.pathExtension
            var name = source.lastPathComponent
            var counter = 2
            while manager.fileExists(atPath: mediaURL.appendingPathComponent(name).path) {
                name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                counter += 1
            }
            let destination = mediaURL.appendingPathComponent(name)
            do {
                try manager.copyItem(at: source, to: destination)
            } catch {
                throw PersistenceError.writeFailed("Could not copy \(source.lastPathComponent): \(error.localizedDescription)")
            }
            var reference = asset.reference
            reference.relativePath = "Media/" + name
            references[asset.id] = reference
            placed[key] = reference.relativePath
            report.copied += 1
            report.bytesCopied += asset.reference.fileSize
        }
        return (references, report)
    }

    // MARK: Storage

    private func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    public func storageUsage() -> StorageUsage {
        StorageUsage(media: size(of: mediaURL), proxies: size(of: proxiesURL), thumbnails: size(of: thumbnailsURL),
                     waveforms: size(of: waveformsURL), cache: size(of: cacheURL), snapshots: size(of: snapshotsURL),
                     exports: size(of: exportsURL))
    }

    /// Deletes regenerable data only (thumbnails, waveforms, render cache, proxies). Returns bytes freed.
    @discardableResult
    public func purgeCaches() -> Int64 {
        let freed = storageUsage().purgeable
        for directory in [thumbnailsURL, waveformsURL, cacheURL, proxiesURL] {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
                for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            }
        }
        return freed
    }
}
