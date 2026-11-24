import AVFoundation
import CoreImage
import Foundation
import MediaServices
import ProjectDomain

/// Everything needed to play or export one sequence.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix?
    public let model: RenderModel
    public let duration: CMTime
    /// Names of media files that could not be found.
    public let missingMedia: [String]
    /// Audio left out because the user marked it as commercial without export rights.
    public let withheldAudio: [MediaAsset]
    public let hasAudio: Bool
    /// Timeline spans that contain sound.
    public let audioRanges: [CMTimeRange]

    /// Whether any sound falls inside a time range.
    public func hasAudio(in range: CMTimeRange) -> Bool {
        audioRanges.contains { $0.intersection(range).duration > .zero }
    }

    /// A player item wired to the custom compositor, for preview.
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

/// Translates a domain sequence into AVFoundation structures: composition tracks for video and
/// audio media, an audio mix for gain and fades, and a render model for everything visual.
public enum CompositionBuilder {
    private struct Lane {
        let track: AVMutableCompositionTrack
        var end: CMTime
    }

    public static func build(project: Project, sequenceID: UUID? = nil, resolver: MediaResolving, outputSize: CGSize? = nil,
                             frameRate: FrameRate? = nil, options: RenderOptions = RenderOptions()) async throws -> BuiltComposition {
        let sequence = sequenceID.flatMap { project.sequence($0) } ?? project.activeSequence
        let duration = sequence.duration
        guard duration.isPositive else { throw RenderError.emptyTimeline }
        let rate = frameRate ?? project.canvas.frameRate
        let canvasSize = CGSize(width: project.canvas.width, height: project.canvas.height)
        let output = outputSize ?? canvasSize
        let composition = AVMutableComposition()
        let total = duration.cmTime

        // Base track: guarantees a video track covering the whole timeline.
        let baseAsset = AVURLAsset(url: try await BaseClip.shared.url())
        if let baseSource = try await baseAsset.loadTracks(withMediaType: .video).first,
           let baseTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let unit = CMTime(seconds: BaseClip.seconds - 0.5, preferredTimescale: 600)
            var cursor = CMTime.zero
            while cursor < total {
                let length = min(unit, total - cursor)
                try baseTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: baseSource, at: cursor)
                cursor = cursor + length
            }
        }

        var assetCache: [UUID: AVURLAsset] = [:]
        var missing: [String] = []
        func avAsset(for asset: MediaAsset) -> AVURLAsset? {
            if let cached = assetCache[asset.id] { return cached }
            guard let url = resolver.url(for: asset) else {
                if !missing.contains(asset.name) { missing.append(asset.name) }
                return nil
            }
            let created = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assetCache[asset.id] = created
            return created
        }

        func insert(_ clip: Clip, source: AVAssetTrack, into lanes: inout [Lane], mediaType: AVMediaType) throws -> CMPersistentTrackID? {
            let start = clip.start.cmTime
            var laneIndex = lanes.firstIndex { $0.end <= start }
            if laneIndex == nil {
                guard let track = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
                lanes.append(Lane(track: track, end: .zero))
                laneIndex = lanes.count - 1
            }
            guard let index = laneIndex else { return nil }
            let sourceRange = CMTimeRange(start: clip.sourceStart.cmTime, duration: clip.sourceDuration.cmTime)
            try lanes[index].track.insertTimeRange(sourceRange, of: source, at: start)
            if clip.speed != 1 {
                lanes[index].track.scaleTimeRange(CMTimeRange(start: start, duration: sourceRange.duration), toDuration: clip.duration.cmTime)
            }
            lanes[index].end = clip.end.cmTime
            return lanes[index].track.trackID
        }

        // Visual layers.
        var videoLanes: [Lane] = []
        var renderTracks: [RenderTrack] = []
        var videoTrackIDs: [CMPersistentTrackID] = []
        var visualClips: [(trackIndex: Int, clip: Clip)] = []
        for (trackIndex, track) in sequence.tracks.enumerated() where track.kind.isVisual && !track.hidden {
            for clip in track.clips { visualClips.append((trackIndex, clip)) }
        }
        var sources: [UUID: LayerSource] = [:]
        // Insert video in start order so every lane is filled left to right.
        for entry in visualClips.sorted(by: { $0.clip.start < $1.clip.start }) {
            let clip = entry.clip
            switch clip.kind {
            case .text:
                sources[clip.id] = .text
            case .solid:
                sources[clip.id] = .solid(clip.solidColor ?? .black)
            case .image:
                if let asset = project.asset(clip.assetID), let url = resolver.url(for: asset) {
                    sources[clip.id] = .image(url)
                } else {
                    let name = project.asset(clip.assetID)?.name ?? clip.name
                    if !missing.contains(name) { missing.append(name) }
                    sources[clip.id] = .offline(name: name)
                }
            case .video:
                guard let asset = project.asset(clip.assetID), let media = avAsset(for: asset),
                      let source = try? await media.loadTracks(withMediaType: .video).first,
                      let trackID = try insert(clip, source: source, into: &videoLanes, mediaType: .video) else {
                    let name = project.asset(clip.assetID)?.name ?? clip.name
                    if !missing.contains(name) { missing.append(name) }
                    sources[clip.id] = .offline(name: name)
                    continue
                }
                if !videoTrackIDs.contains(trackID) { videoTrackIDs.append(trackID) }
                sources[clip.id] = .video(trackID: trackID, rotation: asset.metadata.rotationDegrees)
            case .audio:
                break
            }
        }
        for track in sequence.tracks where track.kind.isVisual && !track.hidden {
            let layers = track.clips.sorted { $0.start < $1.start }.compactMap { clip in
                sources[clip.id].map { RenderLayer(clip: clip, source: $0) }
            }
            renderTracks.append(RenderTrack(kind: track.kind, layers: layers))
        }

        // Audio.
        var audioLanes: [Lane] = []
        var parameters: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        var withheld: [MediaAsset] = []
        var audioRanges: [CMTimeRange] = []
        if !options.silent {
            var audible: [(clip: Clip, trackGain: Double)] = []
            for track in sequence.tracks where !track.muted {
                for clip in track.clips where !clip.audio.muted && (clip.kind == .audio || clip.kind == .video) {
                    audible.append((clip, track.gain))
                }
            }
            for entry in audible.sorted(by: { $0.clip.start < $1.clip.start }) {
                let clip = entry.clip
                guard let asset = project.asset(clip.assetID), asset.metadata.hasAudio else { continue }
                if options.excludeUnlicensedAudio, asset.rights.status == .commercialUnlicensed {
                    if !withheld.contains(where: { $0.id == asset.id }) { withheld.append(asset) }
                    continue
                }
                guard let media = avAsset(for: asset), let source = try? await media.loadTracks(withMediaType: .audio).first,
                      let trackID = try insert(clip, source: source, into: &audioLanes, mediaType: .audio) else { continue }
                let input = parameters[trackID] ?? {
                    let created = AVMutableAudioMixInputParameters()
                    created.trackID = trackID
                    created.audioTimePitchAlgorithm = .spectral
                    parameters[trackID] = created
                    return created
                }()
                applyGain(clip: clip, trackGain: entry.trackGain, to: input, frameDuration: rate.frameDuration)
                audioRanges.append(clip.range.cmTimeRange)
            }
        }
        var audioMix: AVMutableAudioMix?
        if !parameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters.values.sorted { $0.trackID < $1.trackID }
            audioMix = mix
        }

        let model = RenderModel(outputSize: output, canvasSize: canvasSize, background: project.canvas.background, frameRate: rate,
                                duration: duration, options: options, tracks: renderTracks,
                                images: ImageProvider(maxPixel: Int(max(output.width, output.height) * 3)))
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = KirieCompositor.self
        videoComposition.frameDuration = rate.cmFrameDuration
        videoComposition.renderSize = output
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = [KirieInstruction(timeRange: CMTimeRange(start: .zero, duration: total), trackIDs: videoTrackIDs, model: model)]

        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix, model: model,
                                duration: total, missingMedia: missing, withheldAudio: withheld, hasAudio: !audioLanes.isEmpty, audioRanges: audioRanges)
    }

    /// Gain at a moment inside the clip: keyframed (or base) volume × track gain × fade envelope.
    static func gain(of clip: Clip, trackGain: Double, at local: RationalTime) -> Float {
        var value = clip.value(of: .volume, at: local) * trackGain
        let seconds = local.seconds, duration = clip.duration.seconds
        let fadeIn = clip.audio.fadeIn.seconds, fadeOut = clip.audio.fadeOut.seconds
        if fadeIn > 0, seconds < fadeIn { value *= max(0, seconds / fadeIn) }
        if fadeOut > 0, seconds > duration - fadeOut { value *= max(0, (duration - seconds) / fadeOut) }
        return Float(max(0, min(4, value)))
    }

    /// Writes the clip's gain curve as volume ramps between every point where it changes slope.
    static func applyGain(clip: Clip, trackGain: Double, to input: AVMutableAudioMixInputParameters, frameDuration: RationalTime) {
        var points: Set<RationalTime> = [.zero, clip.duration]
        if clip.audio.fadeIn.isPositive { points.insert(clip.audio.fadeIn) }
        if clip.audio.fadeOut.isPositive { points.insert(clip.duration - clip.audio.fadeOut) }
        let volumeFrames = clip.keyframes.filter { $0.property == .volume }.sorted { $0.time < $1.time }
        for (index, frame) in volumeFrames.enumerated() {
            points.insert(frame.time)
            // Eased segments are approximated with short linear ramps.
            if index > 0, frame.easing != .linear, frame.easing != .hold {
                let previous = volumeFrames[index - 1].time
                let span = frame.time - previous
                for step in 1..<8 { points.insert(previous + span.scaled(by: Double(step) / 8)) }
            }
        }
        let ordered = points.filter { !$0.isNegative && $0 <= clip.duration }.sorted()
        for index in 1..<max(1, ordered.count) {
            let a = ordered[index - 1], b = ordered[index]
            guard b > a else { continue }
            // Sample just inside the segment so a step at a boundary lands on the right side.
            let epsilon = RationalTime.min(frameDuration.scaled(by: 0.01), (b - a).scaled(by: 0.01))
            let startGain = gain(of: clip, trackGain: trackGain, at: a + epsilon)
            let endGain = gain(of: clip, trackGain: trackGain, at: b - epsilon)
            input.setVolumeRamp(fromStartVolume: startGain, toEndVolume: endGain,
                                timeRange: CMTimeRange(start: (clip.start + a).cmTime, duration: (b - a).cmTime))
        }
    }
}
