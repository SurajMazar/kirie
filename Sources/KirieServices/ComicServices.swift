import ComicStudio
import CoreGraphics
import Foundation
import MediaServices
import Persistence
import ProjectDomain
import RenderEngine

/// Comic Studio operations that touch files: detection, hashing, approvals, rejected attempts and
/// the image exports. Each returns or executes ordinary edit commands.
extension ProjectSession {
    func stripImage(_ strip: ComicStrip) throws -> (image: CGImage, url: URL, asset: MediaAsset) {
        guard let asset = engine.project.asset(strip.assetID) else { throw ServiceError.notFound("The strip image") }
        guard let url = resolver.url(for: asset) else { throw MediaError.missing(asset.name) }
        return (try Thumbnailer.loadImage(url, maxPixel: 4096), url, asset)
    }

    func strip(_ id: UUID) throws -> ComicStrip {
        guard let strip = engine.project.comic?.strip(id) else { throw EditError.stripNotFound(id) }
        return strip
    }

    /// Turns Comic Studio on if needed, registers an image as a strip and detects its panels.
    @discardableResult
    public func addStrip(assetID: UUID, number: Int? = nil, slug: String? = nil, rightToLeft: Bool = false) throws -> ComicStrip {
        guard let asset = engine.project.asset(assetID), asset.kind == .image else { throw ServiceError.invalid("Choose an image to use as a comic strip.") }
        guard let url = resolver.url(for: asset) else { throw MediaError.missing(asset.name) }
        let image = try Thumbnailer.loadImage(url, maxPixel: 4096)
        var options = PanelDetector.Options()
        options.rightToLeft = rightToLeft
        let analysis = SubjectFinder.analyse(image, options: options)
        let strip = ComicStrip(assetID: assetID, panels: analysis.panels, paperColor: analysis.paper)
        var commands: [EditCommand] = []
        if engine.project.comic == nil {
            let base = (asset.name as NSString).deletingPathExtension
            commands.append(.comic(command: .enable(number: number ?? 1, slug: slug ?? base)))
        }
        commands.append(.comic(command: .addStrip(strip: strip)))
        try execute(commands, label: "Import strip \(asset.name)")
        return strip
    }

    /// Re-runs detection for a strip, replacing its panels (and so invalidating any approval).
    public func redetectPanels(stripID: UUID, rightToLeft: Bool = false) throws -> Int {
        let strip = try strip(stripID)
        let (image, _, _) = try stripImage(strip)
        var options = PanelDetector.Options()
        options.rightToLeft = rightToLeft
        let analysis = SubjectFinder.analyse(image, options: options)
        try execute(.comic(command: .setPanels(stripID: stripID, panels: analysis.panels, paperColor: analysis.paper)))
        return analysis.panels.count
    }

    /// Recomputes content bounds after panels were moved by hand, keeping reviews and manual focus.
    public func refreshSubjects(stripID: UUID) throws {
        let strip = try strip(stripID)
        let (image, _, _) = try stripImage(strip)
        let panels = strip.panels.map { panel -> ComicPanel in
            var updated = panel
            updated.subject = SubjectFinder.contentBounds(in: image, panel: panel.rect)
            return updated
        }
        if panels != strip.panels { try execute(.comic(command: .setPanels(stripID: stripID, panels: panels, paperColor: nil))) }
    }

    /// Framing plan (fit, push-in, crop-safety verdict) for each panel on the project canvas.
    public func framingPlans(stripID: UUID, options: StripReelOptions = StripReelOptions()) throws -> [FramingPlan] {
        let strip = try strip(stripID)
        guard let asset = engine.project.asset(strip.assetID) else { throw ServiceError.notFound("The strip image") }
        let canvas = engine.project.canvas.aspectRatio
        return strip.panels.map { panel in
            let aspect = Double(max(1, asset.metadata.displayWidth)) * panel.rect.width / (Double(max(1, asset.metadata.displayHeight)) * panel.rect.height)
            return FramingPlanner.plan(pictureAspect: aspect, canvasAspect: canvas, subject: panel.subject, focus: panel.focus,
                                       requestedFit: panel.fit, maxZoom: options.maxZoom, margin: options.margin)
        }
    }

    /// Approves a strip: records the SHA-256 of the image file as it is on disk right now, together
    /// with the hash of the review. Fails with the list of blockers if the review is incomplete.
    public func approveStrip(stripID: UUID, approvedBy: String) throws {
        let strip = try strip(stripID)
        guard let comic = engine.project.comic else { throw EditError.stripNotFound(stripID) }
        let (_, url, _) = try stripImage(strip)
        let imageHash = try FileHasher.sha256(of: url)
        let approval = StripApproval(imageHash: imageHash, qaHash: QAGate.stateHash(strip: strip, checklist: comic.checklist),
                                     approvedBy: approvedBy.isEmpty ? NSUserName() : approvedBy)
        try execute(.comic(command: .approveStrip(stripID: stripID, approval: approval)))
    }

    /// Keeps a rejected image inside the project, with the failed checks in its file name.
    @discardableResult
    public func recordRejection(stripID: UUID, imageURL: URL, failedChecks: [String], note: String) throws -> RejectedAttempt {
        _ = try strip(stripID)
        let directory = package.comicURL.appendingPathComponent("rejected", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = try FileHasher.sha256(of: imageURL)
        let checks = failedChecks.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        let base = (imageURL.lastPathComponent as NSString).deletingPathExtension.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let name = "\(base)__FAIL-\(checks.isEmpty ? "unspecified" : checks.joined(separator: "-"))__\(hash.prefix(8)).\(imageURL.pathExtension.isEmpty ? "png" : imageURL.pathExtension)"
        let destination = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: imageURL, to: destination) }
        let attempt = RejectedAttempt(fileName: name, imageHash: hash, failedChecks: checks, note: note)
        try execute(.comic(command: .recordRejection(stripID: stripID, attempt: attempt)))
        return attempt
    }

    /// Attempts used against the configured limit (rejections so far, plus the current image).
    public func attemptStatus(stripID: UUID) throws -> (used: Int, limit: Int, exhausted: Bool) {
        let strip = try strip(stripID)
        let limit = engine.project.comic?.attemptLimit ?? 3
        let used = strip.rejected.count + 1
        return (used, limit, strip.rejected.count >= limit)
    }

    // MARK: Builders

    /// Builds (or rebuilds) a generated timeline and makes it active, as one undo step.
    private func install(_ sequence: Sequence, label: String) throws {
        if engine.project.sequence(sequence.id) != nil {
            try execute([.replaceSequence(sequence: sequence), .setActiveSequence(sequenceID: sequence.id)], label: label)
        } else {
            try execute(.addSequence(sequence: sequence, activate: true))
        }
    }

    private func generatedSequenceID(_ kind: String, _ owner: UUID) -> UUID { UUID(deriving: owner, salt: "generated-\(kind)") }

    @discardableResult
    public func buildStripReel(stripID: UUID, options: StripReelOptions = StripReelOptions()) throws -> Sequence {
        let strip = try strip(stripID)
        let name = (engine.project.asset(strip.assetID).map { ($0.name as NSString).deletingPathExtension } ?? "Strip") + " reel"
        let sequence = try ComicBuilder.stripReel(project: engine.project, stripID: stripID, options: options,
                                                  sequenceID: generatedSequenceID("strip-reel", stripID), name: name)
        try install(sequence, label: "Build strip reel")
        return sequence
    }

    @discardableResult
    public func buildMontage() throws -> Sequence {
        let sequence = try ComicBuilder.montage(project: engine.project, sequenceID: generatedSequenceID("montage", engine.project.id), name: "Montage")
        try install(sequence, label: "Build montage")
        return sequence
    }

    @discardableResult
    public func buildLyricEdit() throws -> Sequence {
        let sequence = try ComicBuilder.lyricEdit(project: engine.project, sequenceID: generatedSequenceID("lyric-edit", engine.project.id), name: "Lyric edit")
        try install(sequence, label: "Build lyric edit")
        return sequence
    }

    // MARK: Review images and exports

    public func contactSheet(stripID: UUID) throws -> CGImage {
        let strip = try strip(stripID)
        let (image, _, _) = try stripImage(strip)
        guard let sheet = ComicSheets.contactSheet(image, panels: strip.panels) else { throw ServiceError.invalid("Detect or draw the panels first.") }
        return sheet
    }

    public func panelZoom(stripID: UUID, panelID: UUID) throws -> CGImage {
        let strip = try strip(stripID)
        guard let panel = strip.panels.first(where: { $0.id == panelID }) else { throw EditError.panelNotFound(panelID) }
        let (image, _, _) = try stripImage(strip)
        guard let zoom = ComicSheets.panelZoom(image, panel: panel.rect) else { throw ServiceError.invalid("The panel is too small to preview.") }
        return zoom
    }

    public func continuitySheet(stripID: UUID, regions: [UnitRect]) throws -> CGImage {
        let strip = try strip(stripID)
        let (image, _, _) = try stripImage(strip)
        guard let sheet = ComicSheets.continuitySheet(image, regions: regions) else { throw ServiceError.invalid("Mark at least one region to compare.") }
        return sheet
    }

    /// Writes 1080×1350 carousel slides for a strip. Subject to the same export lock as video.
    @discardableResult
    public func exportCarousel(stripID: UUID, to directory: URL? = nil, includeFullStrip: Bool = true) throws -> [URL] {
        let lock = exportLock()
        guard !lock.isLocked else { throw RenderError.exportLocked(lock.reasons) }
        let strip = try strip(stripID)
        let (image, _, asset) = try stripImage(strip)
        guard !strip.panels.isEmpty else { throw ServiceError.invalid("Detect or draw the panels first.") }
        let slides = CarouselExporter.slides(image, panels: strip.panels.map(\.rect), paper: strip.paperColor, includeFullStrip: includeFullStrip)
        let folder = directory ?? package.exportsURL.appendingPathComponent(((asset.name as NSString).deletingPathExtension) + " carousel", isDirectory: true)
        return try CarouselExporter.write(slides, to: folder)
    }
}
