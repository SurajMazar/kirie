import Foundation

public struct ValidationIssue: Hashable, Sendable, Codable {
    public enum Severity: String, Sendable, Codable { case error, warning }
    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Structural invariants of a project. Run after every command and when opening a file, so a
/// malformed or hand-edited project is rejected with a clear message instead of misbehaving later.
public enum ProjectValidator {
    public static let maxClips = 100_000
    public static let maxAssets = 50_000

    public static func validate(_ project: Project) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func error(_ message: String) { issues.append(ValidationIssue(.error, message)) }
        func warn(_ message: String) { issues.append(ValidationIssue(.warning, message)) }

        if project.schemaVersion > SchemaVersion.current {
            error("This project was saved by a newer version of Kirie (schema \(project.schemaVersion)).")
        }
        let canvas = project.canvas
        if canvas.width < 16 || canvas.height < 16 || canvas.width > 8192 || canvas.height > 8192 {
            error("Canvas size must be between 16 and 8192 pixels.")
        }
        if canvas.width % 2 != 0 || canvas.height % 2 != 0 { error("Canvas width and height must be even numbers.") }
        if canvas.frameRate.fps < 1 || canvas.frameRate.fps > 240 { error("Frame rate must be between 1 and 240 fps.") }

        if project.assets.count > maxAssets { error("Too many media items (limit \(maxAssets)).") }
        if Set(project.assets.map(\.id)).count != project.assets.count { error("Two media items share an identifier.") }
        let assets = Dictionary(project.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if project.sequences.isEmpty { error("A project needs at least one timeline.") }
        if Set(project.sequences.map(\.id)).count != project.sequences.count { error("Two timelines share an identifier.") }
        if project.sequence(project.activeSequenceID) == nil { error("The active timeline is missing.") }

        var clipIDs = Set<UUID>()
        var clipCount = 0
        let tolerance = canvas.frameRate.frameDuration * 2

        for sequence in project.sequences {
            if sequence.tracks.filter({ $0.kind == .main }).count != 1 {
                error("Timeline “\(sequence.name)” must have exactly one main track.")
            }
            if Set(sequence.tracks.map(\.id)).count != sequence.tracks.count {
                error("Two tracks in “\(sequence.name)” share an identifier.")
            }
            if Set(sequence.markers.map(\.id)).count != sequence.markers.count {
                error("Two markers in “\(sequence.name)” share an identifier.")
            }
            for track in sequence.tracks {
                if !(track.gain.isFinite && track.gain >= 0 && track.gain <= 4) { error("Track “\(track.name)” has an invalid gain.") }
                var previousEnd = RationalTime.zero
                let ordered = track.kind.isMagnetic ? track.clips : track.clips.sorted { $0.start < $1.start }
                for (index, clip) in ordered.enumerated() {
                    clipCount += 1
                    let label = clip.name.isEmpty ? "A \(clip.kind.rawValue) clip" : "“\(clip.name)”"
                    if !clipIDs.insert(clip.id).inserted { error("\(label) shares an identifier with another clip.") }
                    if !track.kind.accepts(clip.kind) { error("\(label) is on a track that cannot hold it.") }
                    if !clip.duration.isPositive { error("\(label) has no duration.") }
                    if clip.start.isNegative { error("\(label) starts before zero.") }
                    if !(clip.speed.isFinite && clip.speed >= 0.1 && clip.speed <= 100) { error("\(label) has an invalid speed.") }
                    if clip.sourceStart.isNegative { error("\(label) starts before its media begins.") }
                    if !clip.transform.crop.isValid { error("\(label) has an invalid crop.") }
                    switch clip.kind {
                    case .video, .image, .audio:
                        guard let asset = assets[clip.assetID ?? UUID()] else {
                            error("\(label) refers to media that is not in the project.")
                            break
                        }
                        let expected: MediaKind = clip.kind == .video ? .video : clip.kind == .image ? .image : .audio
                        let compatible = asset.kind == expected || (clip.kind == .audio && asset.kind == .video && asset.metadata.hasAudio)
                        if !compatible { error("\(label) does not match its media type.") }
                        if clip.usesSourceTiming, clip.sourceEnd > asset.metadata.duration + tolerance {
                            error("\(label) runs past the end of its media.")
                        }
                    case .text:
                        if clip.text == nil { error("\(label) is a text clip without text.") }
                    case .solid:
                        break
                    }
                    for keyframe in clip.keyframes {
                        if !keyframe.value.isFinite { error("\(label) has a keyframe without a value.") }
                        if keyframe.time.isNegative || keyframe.time > clip.duration { error("\(label) has a keyframe outside the clip.") }
                    }
                    if track.kind.isMagnetic {
                        var expectedStart = previousEnd
                        if index > 0, let transition = clip.transitionIn { expectedStart = previousEnd - transition.duration }
                        if clip.start != expectedStart { error("The main track of “\(sequence.name)” has a gap or overlap at \(label).") }
                        if index > 0, let transition = clip.transitionIn {
                            let limit = Sequence.clampedTransitionDuration(transition.duration, previous: ordered[index - 1], next: clip)
                            if transition.duration > limit { error("\(label) has a transition longer than its neighbours allow.") }
                        }
                    } else if index > 0, clip.start < previousEnd {
                        error("Two clips overlap on the “\(track.name)” track.")
                    }
                    previousEnd = clip.end
                }
            }
            for marker in sequence.markers where marker.time.isNegative {
                error("A marker in “\(sequence.name)” sits before zero.")
            }
        }
        if clipCount > maxClips { error("Too many clips (limit \(maxClips)).") }

        if let comic = project.comic {
            if Set(comic.strips.map(\.id)).count != comic.strips.count { error("Two comic strips share an identifier.") }
            for strip in comic.strips {
                if assets[strip.assetID] == nil { error("A comic strip refers to an image that is not in the project.") }
                if strip.panels.contains(where: { !$0.rect.isValid }) { error("A comic panel lies outside its strip.") }
            }
            if !(2...5).contains(comic.synopsis.panelLines.count), !comic.synopsis.panelLines.isEmpty {
                warn("A strip synopsis usually has 2–5 panel lines.")
            }
            if comic.attemptLimit < 1 { error("The attempt limit must be at least 1.") }
        }
        return issues
    }
}
