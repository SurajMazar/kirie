import Foundation
@testable import ProjectDomain

func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

enum Fixture {
    static func video(_ name: String = "clip.mov", duration: Double = 10, audio: Bool = true) -> MediaAsset {
        MediaAsset(name: name, kind: .video, reference: MediaReference(absolutePath: "/tmp/\(name)"),
                   metadata: MediaMetadata(duration: seconds(duration), width: 1920, height: 1080, frameRate: 30,
                                           videoCodec: "avc1", audioChannels: audio ? 2 : 0, sampleRate: audio ? 48_000 : 0,
                                           hasVideo: true, hasAudio: audio))
    }

    static func image(_ name: String = "still.png", width: Int = 1024, height: Int = 1536) -> MediaAsset {
        MediaAsset(name: name, kind: .image, reference: MediaReference(absolutePath: "/tmp/\(name)"),
                   metadata: MediaMetadata(width: width, height: height, hasVideo: true))
    }

    static func audio(_ name: String = "song.m4a", duration: Double = 30) -> MediaAsset {
        MediaAsset(name: name, kind: .audio, reference: MediaReference(absolutePath: "/tmp/\(name)"),
                   metadata: MediaMetadata(duration: seconds(duration), audioChannels: 2, sampleRate: 44_100, hasAudio: true))
    }

    static func reel(name: String = "Test reel") -> Project {
        Project(name: name, canvas: CanvasSettings(width: 1080, height: 1920, frameRate: .fps30),
                createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// A project with three videos, a still and a song imported.
    static func stocked() -> (CommandEngine, [MediaAsset]) {
        var engine = CommandEngine(project: reel())
        let assets = [video("a.mov", duration: 10), video("b.mov", duration: 8), video("c.mov", duration: 6),
                      image("still.png"), audio("song.m4a", duration: 30)]
        // swiftlint:disable:next force_try
        _ = try! engine.execute(.importAssets(assets: assets))
        return (engine, assets)
    }

    @discardableResult
    static func add(_ engine: inout CommandEngine, _ asset: MediaAsset, trackID: UUID? = nil, start: RationalTime? = nil,
                    duration: RationalTime? = nil) throws -> UUID {
        let id = UUID()
        try engine.execute(.addClip(sequenceID: nil, clipID: id, assetID: asset.id, trackID: trackID, start: start,
                                    sourceStart: nil, duration: duration, index: nil))
        return id
    }
}

extension CommandEngine {
    var main: [Clip] { project.activeSequence.mainTrack?.clips ?? [] }
}
