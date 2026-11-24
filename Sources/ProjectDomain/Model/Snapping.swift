import Foundation

public enum SnapKind: String, Sendable, Codable {
    case playhead, clipEdge, marker, beat, sequenceStart, sequenceEnd
}

public struct SnapTarget: Hashable, Sendable {
    public var time: RationalTime
    public var kind: SnapKind

    public init(time: RationalTime, kind: SnapKind) {
        self.time = time
        self.kind = kind
    }
}

public enum Snapping {
    /// All snap candidates of a sequence: playhead, clip edges, markers, beats and the sequence bounds.
    public static func targets(in sequence: Sequence, playhead: RationalTime?, excluding: Set<UUID> = []) -> [SnapTarget] {
        var targets: [SnapTarget] = [SnapTarget(time: .zero, kind: .sequenceStart)]
        if let playhead { targets.append(SnapTarget(time: playhead, kind: .playhead)) }
        for track in sequence.tracks {
            for clip in track.clips where !excluding.contains(clip.id) {
                targets.append(SnapTarget(time: clip.start, kind: .clipEdge))
                targets.append(SnapTarget(time: clip.end, kind: .clipEdge))
            }
        }
        for marker in sequence.markers {
            targets.append(SnapTarget(time: marker.time, kind: marker.kind == .standard || marker.kind == .section ? .marker : .beat))
        }
        targets.append(SnapTarget(time: sequence.duration, kind: .sequenceEnd))
        return targets
    }

    /// Nearest target within `tolerance`, preferring the closest; ties go to the earlier-listed kind.
    public static func snap(_ time: RationalTime, to targets: [SnapTarget], tolerance: RationalTime) -> (time: RationalTime, target: SnapTarget?) {
        var best: SnapTarget?
        var bestDistance = tolerance
        for target in targets {
            let distance = target.time > time ? target.time - time : time - target.time
            if distance < bestDistance || (distance == bestDistance && best == nil && distance <= tolerance) {
                best = target
                bestDistance = distance
            }
        }
        return (best?.time ?? time, best)
    }
}
