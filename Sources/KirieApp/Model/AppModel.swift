import AppKit
import Foundation
import KirieServices
import MediaServices
import Observation
import Persistence
import ProjectDomain
import RenderEngine

enum Destination: String, CaseIterable, Identifiable {
    case home, projects, library, editor, comic, templates, exports, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .projects: "Projects"
        case .library: "Media Library"
        case .editor: "Editor"
        case .comic: "Comic Studio"
        case .templates: "Templates"
        case .exports: "Export Queue"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .projects: "square.grid.2x2"
        case .library: "photo.on.rectangle.angled"
        case .editor: "film.stack"
        case .comic: "rectangle.3.group"
        case .templates: "square.on.square.dashed"
        case .exports: "square.and.arrow.up.on.square"
        case .settings: "gearshape"
        }
    }

    var needsProject: Bool { self == .library || self == .editor || self == .comic }
}

@MainActor
@Observable
final class ExportJob: Identifiable {
    enum State: Equatable {
        case running
        case finished(ExportReport)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let projectName: String
    let timelineName: String
    let preset: ExportPreset
    let destination: URL
    let started = Date()
    var progress: Double = 0
    var state: State = .running
    let cancellation = ExportCancellation()

    init(projectName: String, timelineName: String, preset: ExportPreset, destination: URL) {
        self.projectName = projectName
        self.timelineName = timelineName
        self.preset = preset
        self.destination = destination
    }

    var stage: String {
        switch state {
        case .running: progress < 0.01 ? "Preparing" : progress >= 0.99 ? "Verifying the file" : "Rendering \(Int(progress * 100))%"
        case .finished: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// App-wide state: navigation, the open project, known projects and the export queue.
@MainActor
@Observable
final class AppModel {
    var destination: Destination = .home
    private(set) var editor: EditorModel?
    private(set) var recents: [IndexedProject] = []
    private(set) var posters: [String: NSImage] = [:]
    private(set) var exportJobs: [ExportJob] = []
    var showNewProject = false
    var alertMessage: String?
    private(set) var busyMessage: String?
    @ObservationIgnored private let index: RecentsIndex?
    @ObservationIgnored private var lastPoster = Date.distantPast

    static var defaultFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("Kirie", isDirectory: true)
    }

    var projectFolder: URL {
        if let stored = UserDefaults.standard.string(forKey: "projectFolder"), !stored.isEmpty { return URL(fileURLWithPath: stored) }
        return AppModel.defaultFolder
    }

    init() {
        index = try? RecentsIndex()
        refreshRecents()
        if let raw = UserDefaults.standard.string(forKey: "lastDestination"), let stored = Destination(rawValue: raw), !stored.needsProject {
            destination = stored
        }
    }

    func go(_ destination: Destination) {
        guard !destination.needsProject || editor != nil else { return }
        self.destination = destination
        UserDefaults.standard.set(destination.rawValue, forKey: "lastDestination")
        if destination == .home || destination == .projects { refreshRecents() }
    }

    // MARK: Projects

    func refreshRecents() {
        guard let index else { return }
        _ = try? index.pruneMissing()
        recents = (try? index.list(includeArchived: true)) ?? []
        for project in recents where posters[project.path] == nil {
            let url = project.url.appendingPathComponent("Thumbnails/poster.jpg")
            if let image = NSImage(contentsOf: url) { posters[project.path] = image }
        }
    }

    func rescanProjectFolder() {
        _ = try? index?.rebuild(scanning: [projectFolder])
        refreshRecents()
    }

    func createProject(name: String, canvas: CanvasSettings, in folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).map { $0 == "/" || $0 == ":" ? "-" : $0 }
            var base = String(cleaned).isEmpty ? "Untitled" : String(cleaned)
            var url = folder.appendingPathComponent("\(base).\(ProjectPackage.fileExtension)")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(base) \(counter).\(ProjectPackage.fileExtension)")
                counter += 1
            }
            base = url.deletingPathExtension().lastPathComponent
            let session = try ProjectSession.create(at: url, name: base, canvas: canvas)
            adopt(session)
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func openProject(at url: URL) {
        if editor?.session.package.url == ProjectPackage(url: url).url {
            go(.editor)
            return
        }
        do {
            let (session, opened) = try ProjectSession.open(url)
            adopt(session)
            if case .recoveredFromSnapshot(let snapshot, _) = opened.source {
                editor?.notify(.warning, "The project file was damaged, so Kirie opened the snapshot “\(snapshot.name)” instead.")
            }
            if !opened.missingAssets.isEmpty {
                editor?.notify(.warning, "\(opened.missingAssets.count) media file\(opened.missingAssets.count == 1 ? " is" : "s are") missing. Relink them in the Media Library.",
                               actionTitle: "Show") { [weak self] in self?.go(.library) }
            }
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func chooseProjectToOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: ProjectPackage.fileExtension) ?? .package, .package, .folder]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = projectFolder
        panel.message = "Choose a Kirie project"
        if panel.runModal() == .OK, let url = panel.url { openProject(at: url) }
    }

    private func adopt(_ session: ProjectSession) {
        closeProject()
        let model = EditorModel(session: session)
        model.onSaved = { [weak self] project in self?.projectSaved(project, session: session) }
        editor = model
        try? index?.record(session.project, at: session.package.url)
        // A restore point for this editing session.
        try? session.createSnapshot(name: "Opened", automatic: true)
        refreshRecents()
        if posters[session.package.url.path] == nil {
            lastPoster = .distantPast
            projectSaved(session.project, session: session)
        }
        destination = session.project.comic != nil && session.project.activeSequence.duration.isZero ? .comic : .editor
    }

    func closeProject() {
        guard let editor else { return }
        editor.player.pause()
        editor.saveNow()
        self.editor = nil
        if destination.needsProject { destination = .home }
        refreshRecents()
    }

    private func projectSaved(_ project: Project, session: ProjectSession) {
        try? index?.record(project, at: session.package.url)
        // Refresh the hub poster at most every few seconds.
        guard Date().timeIntervalSince(lastPoster) > 6, project.activeSequence.duration.isPositive else { return }
        lastPoster = Date()
        let resolver = session.resolver
        let posterURL = session.package.thumbnailsURL.appendingPathComponent("poster.jpg")
        let path = session.package.url.path
        Task.detached(priority: .utility) {
            let scale = 360.0 / Double(max(project.canvas.width, project.canvas.height))
            func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
            let size = CGSize(width: even(Double(project.canvas.width) * scale), height: even(Double(project.canvas.height) * scale))
            guard let built = try? await CompositionBuilder.build(project: project, resolver: resolver, outputSize: size),
                  let image = try? await Exporter.still(built: built, at: RationalTime.min(RationalTime(1, 1), project.activeSequence.duration.scaled(by: 0.5)).floored(toFrame: project.canvas.frameRate)),
                  let data = Thumbnailer.encode(image, quality: 0.8) else { return }
            try? data.write(to: posterURL, options: .atomic)
            await MainActor.run { self.posters[path] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        }
    }

    func setArchived(_ archived: Bool, _ project: IndexedProject) {
        try? index?.setArchived(archived, path: project.path)
        refreshRecents()
    }

    func forget(_ project: IndexedProject) {
        try? index?.remove(path: project.path)
        refreshRecents()
    }

    func createDemo() {
        busyMessage = "Building the demo project…"
        let folder = projectFolder
        Task {
            defer { busyMessage = nil }
            do {
                var name = "Kirie Demo"
                var counter = 2
                while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).\(ProjectPackage.fileExtension)").path) {
                    name = "Kirie Demo \(counter)"
                    counter += 1
                }
                let demo = try await DemoBuilder.build(in: folder, name: name)
                openProject(at: demo.projectURL)
            } catch {
                alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Export queue

    @discardableResult
    func startExport(from editor: EditorModel, preset: ExportPreset, destination: URL, range: TimeRange?, options: RenderOptions) -> ExportJob {
        editor.saveNow()
        let job = ExportJob(projectName: editor.project.name, timelineName: editor.sequence.name, preset: preset, destination: destination)
        exportJobs.insert(job, at: 0)
        let session = editor.session
        let sequenceID = editor.sequence.id
        Task {
            do {
                try? session.createSnapshot(name: "Before export", automatic: true)
                let report = try await session.export(preset: preset, to: destination, sequenceID: sequenceID, range: range, options: options,
                                                      cancellation: job.cancellation) { value in
                    Task { @MainActor in job.progress = max(job.progress, value) }
                }
                job.progress = 1
                job.state = .finished(report)
                editor.notify(.success, "Exported \(destination.lastPathComponent)", actionTitle: "Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch RenderError.cancelled {
                job.state = .cancelled
            } catch {
                job.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                editor.notify(.error, "Export failed. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        return job
    }

    func clearFinishedExports() {
        exportJobs.removeAll { $0.state != .running }
    }
}
