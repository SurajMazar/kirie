import Foundation

public enum TrackKind: String, Sendable, Codable, CaseIterable {
    /// The magnetic primary video track. Clips ripple; there is exactly one per sequence.
    case main
    case overlay
    case audio
    case text
    case caption

    public var isVisual: Bool { self != .audio }
    public var isMagnetic: Bool { self == .main }

    public var displayName: String {
        switch self {
        case .main: "Main"
        case .overlay: "Overlay"
        case .audio: "Audio"
        case .text: "Text"
        case .caption: "Captions"
        }
    }

    public func accepts(_ clip: ClipKind) -> Bool {
        switch self {
        case .main: clip == .video || clip == .image || clip == .solid
        case .overlay: clip == .video || clip == .image || clip == .solid
        case .audio: clip == .audio
        case .text, .caption: clip == .text
        }
    }
}

public struct Track: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var kind: TrackKind
    public var name: String
    public var clips: [Clip]
    public var muted: Bool
    public var hidden: Bool
    public var locked: Bool
    /// Linear track gain applied on top of clip gain.
    public var gain: Double

    public init(id: UUID = UUID(), kind: TrackKind, name: String? = nil, clips: [Clip] = [], muted: Bool = false,
                hidden: Bool = false, locked: Bool = false, gain: Double = 1) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.clips = clips
        self.muted = muted
        self.hidden = hidden
        self.locked = locked
        self.gain = gain
    }

    public var end: RationalTime { clips.map(\.end).max() ?? .zero }

    public func clips(at time: RationalTime) -> [Clip] {
        clips.filter { $0.range.contains(time) }
    }

    /// True when `range` would collide with a clip other than `excluding`.
    public func hasOverlap(_ range: TimeRange, excluding: UUID? = nil) -> Bool {
        clips.contains { $0.id != excluding && $0.range.overlaps(range) }
    }
}

public enum MarkerKind: String, Sendable, Codable, CaseIterable {
    case standard, beat, downbeat, section
}

public struct Marker: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var time: RationalTime
    public var kind: MarkerKind
    public var color: RGBAColor
    public var note: String

    public init(id: UUID = UUID(), time: RationalTime, kind: MarkerKind = .standard,
                color: RGBAColor = RGBAColor(r: 0.72, g: 0.62, b: 0.98), note: String = "") {
        self.id = id
        self.time = time
        self.kind = kind
        self.color = color
        self.note = note
    }
}

/// A timeline. Tracks are stored bottom-to-top in render order.
public struct Sequence: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var tracks: [Track]
    public var markers: [Marker]

    public init(id: UUID = UUID(), name: String = "Timeline 1", tracks: [Track]? = nil, markers: [Marker] = []) {
        self.id = id
        self.name = name
        self.tracks = tracks ?? [Track(kind: .main)]
        self.markers = markers
    }

    public var duration: RationalTime { tracks.map(\.end).max() ?? .zero }
    public var allClips: [Clip] { tracks.flatMap(\.clips) }
    public var mainTrackIndex: Int? { tracks.firstIndex { $0.kind == .main } }
    public var mainTrack: Track? { mainTrackIndex.map { tracks[$0] } }

    public func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }
    public func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    /// Locates a clip as (track index, clip index).
    public func locate(_ clipID: UUID) -> (track: Int, clip: Int)? {
        for (ti, track) in tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipID }) { return (ti, ci) }
        }
        return nil
    }

    public func clip(_ id: UUID) -> Clip? {
        locate(id).map { tracks[$0.track].clips[$0.clip] }
    }

    public var beatTimes: [RationalTime] {
        markers.filter { $0.kind == .beat || $0.kind == .downbeat }.map(\.time).sorted()
    }

    // MARK: Magnetic layout

    /// Longest transition that fits between two neighbouring clips: at most half of the shorter one.
    public static func clampedTransitionDuration(_ wanted: RationalTime, previous: Clip, next: Clip) -> RationalTime {
        let half = RationalTime.min(previous.duration, next.duration).scaled(by: 0.5)
        return RationalTime.max(.zero, RationalTime.min(wanted, half))
    }

    /// Re-lays out the main track so clips sit end to end, overlapping only by their transition.
    /// Clips linked to a main-track clip move by the same amount.
    public mutating func rippleMainTrack() {
        guard let mi = mainTrackIndex else { return }
        var deltas: [UUID: RationalTime] = [:]
        var cursor = RationalTime.zero
        for index in tracks[mi].clips.indices {
            var clip = tracks[mi].clips[index]
            var start = cursor
            if index > 0, let transition = clip.transitionIn {
                let previous = tracks[mi].clips[index - 1]
                let overlap = Sequence.clampedTransitionDuration(transition.duration, previous: previous, next: clip)
                clip.transitionIn?.duration = overlap
                start = cursor - overlap
            } else if index == 0, let transition = clip.transitionIn {
                // An entrance on the first clip has nothing to overlap; keep it within the clip.
                clip.transitionIn?.duration = RationalTime.min(transition.duration, clip.duration.scaled(by: 0.5))
            }
            if start != clip.start { deltas[clip.id] = start - clip.start }
            clip.start = start
            tracks[mi].clips[index] = clip
            cursor = clip.end
        }
        guard !deltas.isEmpty else { return }
        for ti in tracks.indices where ti != mi {
            for ci in tracks[ti].clips.indices {
                if let link = tracks[ti].clips[ci].linkedClipID, let delta = deltas[link] {
                    let moved = tracks[ti].clips[ci].start + delta
                    tracks[ti].clips[ci].start = RationalTime.max(.zero, moved)
                }
            }
        }
    }

    /// Keeps free tracks sorted by start so serialisation is deterministic.
    public mutating func normaliseOrder() {
        for ti in tracks.indices where !tracks[ti].kind.isMagnetic {
            tracks[ti].clips.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        }
        markers.sort { $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time }
    }
}
