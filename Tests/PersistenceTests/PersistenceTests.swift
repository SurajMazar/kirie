import Foundation
import Testing
@testable import Persistence
import ProjectDomain

func scratchDirectory(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kirie-tests-\(safe)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sampleProject(name: String = "Persist me") -> Project {
    Project(name: name, canvas: CanvasSettings(width: 1080, height: 1920))
}

/// Writes a small real file and returns an asset pointing at it.
func fileAsset(in directory: URL, name: String, bytes: Int = 4096, fill: UInt8 = 7) throws -> MediaAsset {
    let url = directory.appendingPathComponent(name)
    try Data(repeating: fill, count: bytes).write(to: url)
    let print = try FileHasher.fingerprint(of: url)
    return MediaAsset(name: name, kind: .image,
                      reference: MediaReference(absolutePath: url.path, fileSize: print.size, fingerprint: print.fingerprint),
                      metadata: MediaMetadata(width: 64, height: 64, hasVideo: true))
}

@Suite("Project packages")
struct PackageTests {
    @Test func createSaveAndReopen() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Reel.kirie")
        var project = sampleProject()
        let package = try ProjectPackage.create(at: url, project: project)
        for folder in ["Media", "Proxies", "Thumbnails", "Waveforms", "Snapshots", "Cache", "ComicStudio", "Exports"] {
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(folder).path))
        }
        #expect(throws: PersistenceError.alreadyExists("Reel.kirie")) { try ProjectPackage.create(at: url, project: project) }

        project.name = "Renamed"
        try package.save(project)
        let opened = try ProjectPackage.open(url)
        #expect(opened.project == project)
        #expect(opened.source == .saved)
        #expect(package.readManifest()?.name == "Renamed")
        #expect(package.readManifest()?.schemaVersion == SchemaVersion.current)
        #expect(throws: PersistenceError.notAPackage("nope.kirie")) { try ProjectPackage.open(root.appendingPathComponent("nope.kirie")) }
    }

    @Test func interruptedSaveLeavesThePreviousProjectIntact() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Crash.kirie")
        let project = sampleProject()
        let package = try ProjectPackage.create(at: url, project: project)
        // Simulate a process killed mid-save: a partial temporary file next to the real one.
        let partial = url.appendingPathComponent("project.json\(AtomicFile.temporaryMarker)DEADBEEF")
        try Data("{\"schemaVersion\": 1, \"name\": \"half writ".utf8).write(to: partial)
        let opened = try ProjectPackage.open(url)
        #expect(opened.project == project, "the complete previous save is what opens")
        #expect(opened.removedTemporaryFiles == 1)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        _ = package
    }

    @Test func damagedProjectFallsBackToNewestSnapshot() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Damaged.kirie")
        var project = sampleProject()
        let package = try ProjectPackage.create(at: url, project: project)
        try package.createSnapshot(project, name: "First", date: Date(timeIntervalSince1970: 1_800_000_000))
        project.name = "Later state"
        try package.createSnapshot(project, name: "Second / with:odd*chars", date: Date(timeIntervalSince1970: 1_800_000_100))
        try Data("garbage".utf8).write(to: package.projectURL)

        let opened = try ProjectPackage.open(url)
        #expect(opened.project.name == "Later state")
        guard case .recoveredFromSnapshot(let snapshot, _) = opened.source else {
            Issue.record("expected snapshot recovery")
            return
        }
        #expect(snapshot.name == "Second _ with_odd_chars")

        // With no snapshot to fall back on, the damage is reported rather than hidden.
        for snapshot in package.listSnapshots() { try package.deleteSnapshot(snapshot) }
        #expect(throws: ProjectFileError.self) { try ProjectPackage.open(url) }
    }

    @Test func newerFormatIsNeverReplacedByASnapshot() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Future.kirie")
        let project = sampleProject()
        let package = try ProjectPackage.create(at: url, project: project)
        try package.createSnapshot(project, name: "Old")
        try Data("{\"schemaVersion\": 42}".utf8).write(to: package.projectURL)
        #expect(throws: ProjectFileError.newerSchema(found: 42, supported: SchemaVersion.current)) { try ProjectPackage.open(url) }
    }

    @Test func snapshotsListRestoreAndPrune() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = sampleProject()
        let package = try ProjectPackage.create(at: root.appendingPathComponent("Snap.kirie"), project: project)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<14 {
            project.name = "Auto \(index)"
            try package.createSnapshot(project, name: "Autosave", automatic: true, date: base.addingTimeInterval(Double(index)))
        }
        project.name = "Milestone"
        let named = try package.createSnapshot(project, name: "Before recut", date: base.addingTimeInterval(100))
        let listed = package.listSnapshots()
        #expect(listed.filter(\.automatic).count == 10, "automatic snapshots are pruned")
        #expect(listed.first == named, "newest first")
        #expect(try package.loadSnapshot(named).name == "Milestone")
        #expect(try package.loadSnapshot(listed.last!).name == "Auto 4")
        #expect(throws: PersistenceError.self) {
            try package.loadSnapshot(SnapshotInfo(fileName: "../project.json", name: "escape", createdAt: base, automatic: false))
        }
    }

    @Test func collectMakesAProjectPortable() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources")
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let a = try fileAsset(in: sources, name: "a.png", fill: 1)
        let duplicate = try fileAsset(in: other, name: "copy-of-a.png", fill: 1)
        let clash = try fileAsset(in: other, name: "a.png", bytes: 5000, fill: 2)
        var gone = try fileAsset(in: sources, name: "gone.png", fill: 3)
        try FileManager.default.removeItem(atPath: gone.reference.absolutePath)
        gone.name = "gone.png"

        var project = sampleProject()
        project.assets = [a, duplicate, clash, gone]
        let url = root.appendingPathComponent("Portable.kirie")
        let package = try ProjectPackage.create(at: url, project: project)
        #expect(package.collectEstimate(for: project) == 4096 + 5000)
        #expect(package.missingAssets(in: project).map(\.name) == ["gone.png"])

        let (references, report) = try package.collect(project)
        #expect(report == CollectReport(copied: 2, alreadyInside: 0, deduplicated: 1, missing: ["gone.png"], bytesCopied: 9096))
        for index in project.assets.indices {
            if let reference = references[project.assets[index].id] { project.assets[index].reference = reference }
        }
        #expect(project.assets[0].reference.relativePath == "Media/a.png")
        #expect(project.assets[1].reference.relativePath == "Media/a.png", "identical content is stored once")
        #expect(project.assets[2].reference.relativePath == "Media/a 2.png", "same name, different content gets its own file")
        try package.save(project)

        // Move the package and delete the originals: every collected link still resolves.
        let moved = root.appendingPathComponent("Elsewhere/Moved.kirie")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.removeItem(at: sources)
        try FileManager.default.removeItem(at: other)
        let reopened = try ProjectPackage.open(moved)
        #expect(reopened.missingAssets.map(\.name) == ["gone.png"])
        let resolved = try #require(reopened.package.resolve(reopened.project.assets[2].reference))
        #expect(try Data(contentsOf: resolved).count == 5000)

        // Collecting again copies nothing.
        let again = try reopened.package.collect(reopened.project)
        #expect(again.report.copied == 0 && again.report.alreadyInside == 3)
    }

    @Test func relativePathsCannotEscapeThePackage() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let package = try ProjectPackage.create(at: root.appendingPathComponent("Safe.kirie"), project: sampleProject())
        let escaping = MediaReference(absolutePath: "", relativePath: "../secret.txt")
        #expect(package.resolve(escaping) == nil)
        let inside = MediaReference(absolutePath: "", relativePath: "Media/../../secret.txt")
        #expect(package.resolve(inside) == nil)
    }

    @Test func storageAccountingAndSafePurge() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try ProjectPackage.create(at: root.appendingPathComponent("Store.kirie"), project: sampleProject())
        try Data(count: 1000).write(to: package.thumbnailsURL.appendingPathComponent("t.jpg"))
        try Data(count: 2000).write(to: package.waveformsURL.appendingPathComponent("w.bin"))
        try Data(count: 3000).write(to: package.mediaURL.appendingPathComponent("keep.mov"))
        let usage = package.storageUsage()
        #expect(usage.thumbnails == 1000 && usage.waveforms == 2000 && usage.media == 3000)
        #expect(usage.purgeable == 3000)
        #expect(package.purgeCaches() == 3000)
        #expect(package.storageUsage().purgeable == 0)
        #expect(package.storageUsage().media == 3000, "media is never purged")
        #expect(FileManager.default.fileExists(atPath: package.projectURL.path))
    }

    @Test func relinkSuggestsMovedFilesByContent() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original")
        let moved = root.appendingPathComponent("Moved/Deep")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let asset = try fileAsset(in: original, name: "shot.png", fill: 9)
        try FileManager.default.moveItem(atPath: asset.reference.absolutePath, toPath: moved.appendingPathComponent("renamed.png").path)
        try Data(repeating: 4, count: 4096).write(to: moved.appendingPathComponent("shot.png"))
        try Data(repeating: 5, count: 10).write(to: moved.appendingPathComponent("unrelated.txt"))

        let candidates = RelinkFinder.candidates(for: asset, in: root)
        #expect(candidates.first?.url.lastPathComponent == "renamed.png", "same content beats same name")
        #expect(candidates.first?.reasons.contains("same content") == true)
        #expect(candidates.contains { $0.url.lastPathComponent == "shot.png" })
        #expect(!candidates.contains { $0.url.lastPathComponent == "unrelated.txt" })
    }

    @Test func hashesDetectAnyChange() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        try Data(repeating: 1, count: 3_000_000).write(to: file)
        let before = try FileHasher.sha256(of: file)
        #expect(before.count == 64)
        var bytes = try Data(contentsOf: file)
        bytes[1_500_000] = 2
        try bytes.write(to: file)
        #expect(try FileHasher.sha256(of: file) != before, "a change in the middle changes the full hash")
        #expect(throws: PersistenceError.self) { try FileHasher.sha256(of: root.appendingPathComponent("missing")) }
    }
}

@Suite("Recents index")
struct RecentsIndexTests {
    @Test func recordsSearchesAndRebuilds() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try RecentsIndex(url: root.appendingPathComponent("index.sqlite"))
        var urls: [URL] = []
        for (offset, name) in ["Beach day", "Rainy 100% day", "Lyric_edit"].enumerated() {
            let url = root.appendingPathComponent("\(name).kirie")
            let project = sampleProject(name: name)
            _ = try ProjectPackage.create(at: url, project: project)
            try index.record(project, at: url, opened: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset)))
            urls.append(url)
        }
        #expect(try index.list().map(\.name) == ["Lyric_edit", "Rainy 100% day", "Beach day"])
        #expect(try index.list(search: "day").count == 2)
        #expect(try index.list(search: "100%").map(\.name) == ["Rainy 100% day"], "LIKE wildcards are escaped")
        #expect(try index.list(search: "'; DROP TABLE projects; --").isEmpty)
        #expect(try index.list().count == 3, "the injection attempt changed nothing")

        try index.setArchived(true, path: urls[0].standardizedFileURL.path)
        #expect(try index.list().count == 2)
        #expect(try index.list(includeArchived: true).count == 3)

        try FileManager.default.removeItem(at: urls[1])
        #expect(try index.pruneMissing() == 1)

        // The index is disposable: a fresh database rebuilt from disk finds the same projects.
        let rebuilt = try RecentsIndex(url: root.appendingPathComponent("fresh.sqlite"))
        #expect(try rebuilt.rebuild(scanning: [root]) == 2)
        #expect(Set(try rebuilt.list().map(\.name)) == ["Beach day", "Lyric_edit"])
    }
}
