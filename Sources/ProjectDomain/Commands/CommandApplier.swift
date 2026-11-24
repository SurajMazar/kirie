import CryptoKit
import Foundation

extension UUID {
    /// Deterministic identifier derived from another one, so commands that need to create secondary
    /// objects (for example an audio track for a detached clip) stay replayable.
    public init(deriving base: UUID, salt: String) {
        var hasher = SHA256()
        hasher.update(data: Data(base.uuidString.utf8))
        hasher.update(data: Data(salt.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Applies one command to a project value. Pure and deterministic: same project + same command
/// always gives the same result, and nothing outside the returned project is touched.
struct CommandApplier {
    var project: Project

    static let defaultStillDuration = RationalTime(seconds: 3)
    static let speedRange = 0.1...100.0

    private var rate: FrameRate { project.canvas.frameRate }
    private var oneFrame: RationalTime { rate.frameDuration }
    private func quantise(_ time: RationalTime) -> RationalTime { time.rounded(toFrame: rate) }

    // MARK: Lookup

    private func sequenceIndex(_ id: UUID?) throws -> Int {
        let wanted = id ?? project.activeSequenceID
        guard let index = project.sequenceIndex(wanted) else { throw EditError.sequenceNotFound(wanted) }
        return index
    }

    private func locate(_ clipID: UUID) throws -> (s: Int, t: Int, c: Int) {
        guard let hit = project.locateClip(clipID) else { throw EditError.clipNotFound(clipID) }
        return (hit.sequence, hit.track, hit.clip)
    }

    private func locateTrack(_ trackID: UUID) throws -> (s: Int, t: Int) {
        for (si, sequence) in project.sequences.enumerated() {
            if let ti = sequence.trackIndex(trackID) { return (si, ti) }
        }
        throw EditError.trackNotFound(trackID)
    }

    private func requireUnlocked(_ s: Int, _ t: Int) throws {
        let track = project.sequences[s].tracks[t]
        if track.locked { throw EditError.trackLocked(track.name) }
    }

    private func requireAsset(_ id: UUID) throws -> MediaAsset {
        guard let asset = project.asset(id) else { throw EditError.assetNotFound(id) }
        return asset
    }

    /// Longest timeline duration the clip's source can supply from `sourceStart`.
    private func availableDuration(kind: ClipKind, assetID: UUID?, sourceStart: RationalTime, speed: Double) -> RationalTime? {
        guard kind == .video || kind == .audio, let asset = project.asset(assetID) else { return nil }
        let remaining = asset.metadata.duration - sourceStart
        return speed == 1 ? remaining : remaining.scaled(by: 1 / speed)
    }

    /// Re-establishes the timeline invariants after an edit.
    mutating func settle() {
        for index in project.sequences.indices {
            project.sequences[index].rippleMainTrack()
            project.sequences[index].normaliseOrder()
        }
    }

    // MARK: Dispatch

    mutating func apply(_ command: EditCommand) throws -> String {
        switch command {
        case .renameProject(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else { throw EditError.invalid("Enter a project name up to 200 characters.") }
            project.name = trimmed
            return "Rename project"

        case .setCanvas(let canvas):
            project.canvas = canvas
            return "Change canvas"

        case .setExportPreset(let presetID):
            guard presetID == "custom" || ExportPreset.named(presetID) != nil else {
                throw EditError.invalid("Unknown export preset '\(presetID)'.")
            }
            project.exportPresetID = presetID
            return "Set export preset"

        case .importAssets(let assets):
            guard !assets.isEmpty else { throw EditError.invalid("No media to import.") }
            for asset in assets where project.asset(asset.id) == nil {
                project.assets.append(asset)
            }
            return assets.count == 1 ? "Import \(assets[0].name)" : "Import \(assets.count) items"

        case .removeAsset(let assetID):
            let asset = try requireAsset(assetID)
            if project.isAssetInUse(assetID) { throw EditError.assetInUse(asset.name) }
            project.assets.removeAll { $0.id == assetID }
            return "Remove \(asset.name)"

        case .updateAssetInfo(let assetID, let name, let rights, let favourite, let rating, let keywords, let bpm):
            guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { throw EditError.assetNotFound(assetID) }
            if let name, !name.isEmpty { project.assets[index].name = String(name.prefix(200)) }
            if let rights { project.assets[index].rights = rights }
            if let favourite { project.assets[index].favourite = favourite }
            if let rating { project.assets[index].rating = max(0, min(5, rating)) }
            if let keywords { project.assets[index].keywords = keywords.map { String($0.prefix(60)) } }
            if let bpm { project.assets[index].bpm = bpm.isFinite && bpm > 0 ? bpm : nil }
            return "Update media info"

        case .relinkAsset(let assetID, let reference):
            guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { throw EditError.assetNotFound(assetID) }
            project.assets[index].reference = reference
            return "Relink \(project.assets[index].name)"

        case .addSequence(let sequence, let activate):
            guard project.sequence(sequence.id) == nil else { throw EditError.invalid("A timeline with this identifier already exists.") }
            project.sequences.append(sequence)
            if activate { project.activeSequenceID = sequence.id }
            return "Add timeline \(sequence.name)"

        case .replaceSequence(let sequence):
            guard let index = project.sequenceIndex(sequence.id) else { throw EditError.sequenceNotFound(sequence.id) }
            project.sequences[index] = sequence
            return "Rebuild \(sequence.name)"

        case .removeSequence(let sequenceID):
            guard let index = project.sequenceIndex(sequenceID) else { throw EditError.sequenceNotFound(sequenceID) }
            guard project.sequences.count > 1 else { throw EditError.invalid("A project needs at least one timeline.") }
            project.sequences.remove(at: index)
            if project.activeSequenceID == sequenceID { project.activeSequenceID = project.sequences[0].id }
            return "Remove timeline"

        case .setActiveSequence(let sequenceID):
            guard project.sequenceIndex(sequenceID) != nil else { throw EditError.sequenceNotFound(sequenceID) }
            project.activeSequenceID = sequenceID
            return "Switch timeline"

        case .renameSequence(let sequenceID, let name):
            guard let index = project.sequenceIndex(sequenceID) else { throw EditError.sequenceNotFound(sequenceID) }
            guard !name.isEmpty else { throw EditError.invalid("Enter a timeline name.") }
            project.sequences[index].name = String(name.prefix(120))
            return "Rename timeline"

        case .addTrack(let sequenceID, let trackID, let kind, let name, let index):
            let s = try sequenceIndex(sequenceID)
            guard kind != .main else { throw EditError.invalid("A timeline has exactly one main track.") }
            guard project.sequences[s].trackIndex(trackID) == nil else { throw EditError.invalid("A track with this identifier already exists.") }
            let number = project.sequences[s].tracks.filter { $0.kind == kind }.count + 1
            let track = Track(id: trackID, kind: kind, name: name ?? "\(kind.displayName) \(number)")
            let at = max(0, min(index ?? project.sequences[s].tracks.count, project.sequences[s].tracks.count))
            project.sequences[s].tracks.insert(track, at: at)
            return "Add \(kind.displayName.lowercased()) track"

        case .removeTrack(let trackID):
            let (s, t) = try locateTrack(trackID)
            guard project.sequences[s].tracks[t].kind != .main else { throw EditError.invalid("The main track cannot be removed.") }
            try requireUnlocked(s, t)
            let removed = Set(project.sequences[s].tracks[t].clips.map(\.id))
            project.sequences[s].tracks.remove(at: t)
            clearLinks(to: removed, in: s)
            return "Remove track"

        case .setTrackState(let trackID, let muted, let hidden, let locked, let gain, let name):
            let (s, t) = try locateTrack(trackID)
            if let muted { project.sequences[s].tracks[t].muted = muted }
            if let hidden { project.sequences[s].tracks[t].hidden = hidden }
            if let locked { project.sequences[s].tracks[t].locked = locked }
            if let gain {
                guard gain.isFinite, gain >= 0, gain <= 4 else { throw EditError.invalid("Track gain must be between 0 and 4.") }
                project.sequences[s].tracks[t].gain = gain
            }
            if let name, !name.isEmpty { project.sequences[s].tracks[t].name = String(name.prefix(80)) }
            return "Update track"

        case .addClip(let sequenceID, let clipID, let assetID, let trackID, let start, let sourceStart, let duration, let index):
            return try addClip(sequenceID: sequenceID, clipID: clipID, assetID: assetID, trackID: trackID, start: start,
                               sourceStart: sourceStart, duration: duration, index: index)

        case .insertClip(let sequenceID, let trackID, let clip, let index):
            let s = try sequenceIndex(sequenceID)
            guard project.locateClip(clip.id) == nil else { throw EditError.invalid("A clip with this identifier already exists.") }
            var placed = clip
            placed.start = quantise(RationalTime.max(.zero, clip.start))
            placed.duration = RationalTime.max(oneFrame, quantise(clip.duration))
            try place(placed, sequence: s, trackID: trackID, index: index)
            return "Add \(clip.kind == .text ? "text" : clip.kind.rawValue)"

        case .removeClips(let clipIDs, let ripple):
            guard !clipIDs.isEmpty else { throw EditError.invalid("Select a clip to delete.") }
            for clipID in clipIDs {
                let (s, t, c) = try locate(clipID)
                try requireUnlocked(s, t)
                let removed = project.sequences[s].tracks[t].clips.remove(at: c)
                if ripple, !project.sequences[s].tracks[t].kind.isMagnetic {
                    for ci in project.sequences[s].tracks[t].clips.indices
                    where project.sequences[s].tracks[t].clips[ci].start >= removed.end {
                        project.sequences[s].tracks[t].clips[ci].start -= removed.duration
                    }
                }
                clearLinks(to: [clipID], in: s)
            }
            return clipIDs.count == 1 ? (ripple ? "Ripple delete" : "Delete clip") : "Delete \(clipIDs.count) clips"

        case .moveClip(let clipID, let toTrackID, let start, let index):
            return try moveClip(clipID: clipID, toTrackID: toTrackID, start: start, index: index)

        case .trimClip(let clipID, let edge, let to):
            return try trimClip(clipID: clipID, edge: edge, to: to)

        case .splitClip(let clipID, let at, let newClipID):
            return try splitClip(clipID: clipID, at: at, newClipID: newClipID)

        case .duplicateClip(let clipID, let newClipID):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            guard project.locateClip(newClipID) == nil else { throw EditError.invalid("A clip with this identifier already exists.") }
            var copy = project.sequences[s].tracks[t].clips[c]
            copy.id = newClipID
            copy.linkedClipID = nil
            copy.keyframes = copy.keyframes.map { var k = $0; k.id = UUID(deriving: $0.id, salt: newClipID.uuidString); return k }
            if project.sequences[s].tracks[t].kind.isMagnetic {
                copy.transitionIn = nil
                project.sequences[s].tracks[t].clips.insert(copy, at: c + 1)
            } else {
                copy.start = firstFreeStart(in: project.sequences[s].tracks[t], from: copy.end, duration: copy.duration)
                project.sequences[s].tracks[t].clips.append(copy)
            }
            return "Duplicate clip"

        case .renameClip(let clipID, let name):
            let (s, t, c) = try locate(clipID)
            project.sequences[s].tracks[t].clips[c].name = String(name.prefix(120))
            return "Rename clip"

        case .setTransform(let clipID, let transform):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            let values = [transform.position.x, transform.position.y, transform.scale, transform.rotation, transform.opacity]
            guard values.allSatisfy(\.isFinite) else { throw EditError.invalid("Transform values must be numbers.") }
            guard transform.scale >= 0.01, transform.scale <= 50 else { throw EditError.invalid("Scale must be between 1% and 5000%.") }
            guard transform.crop.isValid else { throw EditError.invalid("The crop must stay inside the picture.") }
            var cleaned = transform
            cleaned.opacity = max(0, min(1, transform.opacity))
            project.sequences[s].tracks[t].clips[c].transform = cleaned
            return "Transform"

        case .setKeyframe(let clipID, let keyframe):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            let clip = project.sequences[s].tracks[t].clips[c]
            guard keyframe.value.isFinite else { throw EditError.invalid("Keyframe values must be numbers.") }
            var placed = keyframe
            placed.time = quantise(keyframe.time).clamped(.zero, clip.duration)
            var frames = clip.keyframes.filter { $0.id != placed.id && !($0.property == placed.property && $0.time == placed.time) }
            frames.append(placed)
            frames.sort { $0.property.rawValue == $1.property.rawValue ? $0.time < $1.time : $0.property.rawValue < $1.property.rawValue }
            project.sequences[s].tracks[t].clips[c].keyframes = frames
            return "Set \(keyframe.property.displayName.lowercased()) keyframe"

        case .removeKeyframe(let clipID, let keyframeID):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            project.sequences[s].tracks[t].clips[c].keyframes.removeAll { $0.id == keyframeID }
            return "Remove keyframe"

        case .clearKeyframes(let clipID, let property):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            project.sequences[s].tracks[t].clips[c].keyframes.removeAll { property == nil || $0.property == property }
            return "Clear keyframes"

        case .setTransition(let clipID, let transition):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            if let transition {
                guard transition.duration.isPositive else { throw EditError.invalid("A transition needs a duration.") }
                var placed = transition
                placed.duration = RationalTime.max(oneFrame, quantise(transition.duration))
                project.sequences[s].tracks[t].clips[c].transitionIn = placed
                return "Add \(transition.type.displayName.lowercased()) transition"
            }
            project.sequences[s].tracks[t].clips[c].transitionIn = nil
            return "Remove transition"

        case .setClipAudio(let clipID, let audio):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            guard audio.gain.isFinite, audio.gain >= 0, audio.gain <= 4 else { throw EditError.invalid("Volume must be between 0 and 400%.") }
            let duration = project.sequences[s].tracks[t].clips[c].duration
            var cleaned = audio
            cleaned.fadeIn = quantise(audio.fadeIn).clamped(.zero, duration)
            cleaned.fadeOut = quantise(audio.fadeOut).clamped(.zero, duration - cleaned.fadeIn)
            project.sequences[s].tracks[t].clips[c].audio = cleaned
            return "Adjust audio"

        case .detachAudio(let clipID, let newClipID, let newTrackID):
            return try detachAudio(clipID: clipID, newClipID: newClipID, newTrackID: newTrackID)

        case .setSpeed(let clipID, let speed):
            return try setSpeed(clipID: clipID, speed: speed)

        case .setText(let clipID, let text):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            guard project.sequences[s].tracks[t].clips[c].kind == .text else { throw EditError.invalid("Only text clips have text.") }
            guard text.string.count <= 5_000 else { throw EditError.invalid("Text is limited to 5,000 characters.") }
            project.sequences[s].tracks[t].clips[c].text = text
            if project.sequences[s].tracks[t].clips[c].name.isEmpty || text.role != .lyric {
                project.sequences[s].tracks[t].clips[c].name = String(text.string.prefix(40))
            }
            return "Edit text"

        case .setLook(let clipID, let color, let filters, let blendMode, let mask, let chromaKey):
            let (s, t, c) = try locate(clipID)
            try requireUnlocked(s, t)
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? max(lo, min(hi, v)) : 0 }
            var cleaned = color
            cleaned.exposure = clamp(color.exposure, -3, 3)
            cleaned.contrast = clamp(color.contrast, -1, 1)
            cleaned.highlights = clamp(color.highlights, -1, 1)
            cleaned.shadows = clamp(color.shadows, -1, 1)
            cleaned.saturation = clamp(color.saturation, -1, 1)
            cleaned.temperature = clamp(color.temperature, -1, 1)
            cleaned.tint = clamp(color.tint, -1, 1)
            cleaned.vignette = clamp(color.vignette, 0, 1)
            cleaned.sharpen = clamp(color.sharpen, 0, 1)
            if let mask, !mask.rect.isValid { throw EditError.invalid("The mask must stay inside the clip.") }
            project.sequences[s].tracks[t].clips[c].color = cleaned
            project.sequences[s].tracks[t].clips[c].filters = filters.map {
                var f = $0; f.intensity = clamp($0.intensity, 0, 1); return f
            }
            project.sequences[s].tracks[t].clips[c].blendMode = blendMode
            project.sequences[s].tracks[t].clips[c].mask = mask
            project.sequences[s].tracks[t].clips[c].chromaKey = chromaKey
            return "Adjust look"

        case .closeGaps(let trackID):
            let (s, t) = try locateTrack(trackID)
            try requireUnlocked(s, t)
            guard !project.sequences[s].tracks[t].kind.isMagnetic else { return "Close gaps" }
            var cursor = RationalTime.zero
            let order = project.sequences[s].tracks[t].clips.indices.sorted {
                project.sequences[s].tracks[t].clips[$0].start < project.sequences[s].tracks[t].clips[$1].start
            }
            for ci in order {
                project.sequences[s].tracks[t].clips[ci].start = cursor
                cursor = project.sequences[s].tracks[t].clips[ci].end
            }
            return "Close gaps"

        case .addMarkers(let sequenceID, let markers):
            let s = try sequenceIndex(sequenceID)
            guard !markers.isEmpty else { throw EditError.invalid("No markers to add.") }
            for marker in markers where !project.sequences[s].markers.contains(where: { $0.id == marker.id }) {
                var placed = marker
                placed.time = RationalTime.max(.zero, marker.time)
                placed.note = String(marker.note.prefix(500))
                project.sequences[s].markers.append(placed)
            }
            return markers.count == 1 ? "Add marker" : "Add \(markers.count) markers"

        case .removeMarkers(let markerIDs):
            let ids = Set(markerIDs)
            var removed = 0
            for s in project.sequences.indices {
                let before = project.sequences[s].markers.count
                project.sequences[s].markers.removeAll { ids.contains($0.id) }
                removed += before - project.sequences[s].markers.count
            }
            guard removed > 0 else { throw EditError.markerNotFound(markerIDs.first ?? UUID()) }
            return removed == 1 ? "Remove marker" : "Remove \(removed) markers"

        case .moveMarker(let markerID, let to):
            for s in project.sequences.indices {
                if let m = project.sequences[s].markers.firstIndex(where: { $0.id == markerID }) {
                    project.sequences[s].markers[m].time = RationalTime.max(.zero, to)
                    return "Move marker"
                }
            }
            throw EditError.markerNotFound(markerID)

        case .replaceBeatMarkers(let sequenceID, let markers):
            let s = try sequenceIndex(sequenceID)
            guard markers.allSatisfy({ $0.kind == .beat || $0.kind == .downbeat }) else {
                throw EditError.invalid("Only beat markers can be set with this command.")
            }
            project.sequences[s].markers.removeAll { $0.kind == .beat || $0.kind == .downbeat }
            project.sequences[s].markers.append(contentsOf: markers.map {
                var m = $0; m.time = RationalTime.max(.zero, $0.time); return m
            })
            return "Set \(markers.count) beat markers"

        case .cutToBeat(let clipIDs, let every):
            return try cutToBeat(clipIDs: clipIDs, every: every)

        case .replaceCaptions(let sequenceID, let trackID, let segments, let style, let animation):
            return try replaceCaptions(sequenceID: sequenceID, trackID: trackID, segments: segments, style: style, animation: animation)

        case .comic(let command):
            return try applyComic(command)
        }
    }

    // MARK: Clip placement

    private mutating func clearLinks(to removed: Set<UUID>, in s: Int) {
        for ti in project.sequences[s].tracks.indices {
            for ci in project.sequences[s].tracks[ti].clips.indices {
                if let link = project.sequences[s].tracks[ti].clips[ci].linkedClipID, removed.contains(link) {
                    project.sequences[s].tracks[ti].clips[ci].linkedClipID = nil
                }
            }
        }
    }

    private func firstFreeStart(in track: Track, from: RationalTime, duration: RationalTime, excluding: UUID? = nil) -> RationalTime {
        var start = RationalTime.max(.zero, from)
        let sorted = track.clips.filter { $0.id != excluding }.sorted { $0.start < $1.start }
        for clip in sorted where clip.range.overlaps(TimeRange(start: start, duration: duration)) {
            start = clip.end
        }
        return start
    }

    /// Puts a fully formed clip on a track. With no track given, picks the natural one for its kind.
    private mutating func place(_ clip: Clip, sequence s: Int, trackID: UUID?, index: Int?) throws {
        let t: Int
        if let trackID {
            guard let found = project.sequences[s].trackIndex(trackID) else { throw EditError.trackNotFound(trackID) }
            t = found
        } else {
            let wanted: TrackKind = switch clip.kind {
            case .audio: .audio
            case .text: clip.text?.role == .caption ? .caption : .text
            default: .main
            }
            if wanted == .main, let mi = project.sequences[s].mainTrackIndex {
                t = mi
            } else if let free = project.sequences[s].tracks.firstIndex(where: {
                $0.kind == wanted && !$0.locked && !$0.hasOverlap(clip.range)
            }) {
                t = free
            } else {
                let number = project.sequences[s].tracks.filter { $0.kind == wanted }.count + 1
                let track = Track(id: UUID(deriving: clip.id, salt: "track"), kind: wanted, name: "\(wanted.displayName) \(number)")
                project.sequences[s].tracks.append(track)
                t = project.sequences[s].tracks.count - 1
            }
        }
        let track = project.sequences[s].tracks[t]
        if track.locked { throw EditError.trackLocked(track.name) }
        guard track.kind.accepts(clip.kind) else {
            throw EditError.invalid("A \(clip.kind.rawValue) clip cannot go on the \(track.name) track.")
        }
        if track.kind.isMagnetic {
            let at = max(0, min(index ?? track.clips.count, track.clips.count))
            project.sequences[s].tracks[t].clips.insert(clip, at: at)
        } else {
            if track.hasOverlap(clip.range) {
                throw EditError.overlap("There is already a clip at that position on the \(track.name) track.")
            }
            project.sequences[s].tracks[t].clips.append(clip)
        }
    }

    private mutating func addClip(sequenceID: UUID?, clipID: UUID, assetID: UUID, trackID: UUID?, start: RationalTime?,
                                  sourceStart: RationalTime?, duration: RationalTime?, index: Int?) throws -> String {
        let s = try sequenceIndex(sequenceID)
        let asset = try requireAsset(assetID)
        guard project.locateClip(clipID) == nil else { throw EditError.invalid("A clip with this identifier already exists.") }
        let kind: ClipKind = switch asset.kind {
        case .video: .video
        case .image: .image
        case .audio: .audio
        }
        let source = RationalTime.max(.zero, sourceStart ?? .zero)
        var length: RationalTime
        if let available = availableDuration(kind: kind, assetID: assetID, sourceStart: source, speed: 1) {
            guard available.isPositive else { throw EditError.invalid("\(asset.name) has no media after that point.") }
            let wanted = duration.map { RationalTime.min($0, available) } ?? available
            length = wanted.floored(toFrame: rate)
            if !length.isPositive { length = RationalTime.min(oneFrame, available) }
        } else {
            length = RationalTime.max(oneFrame, quantise(duration ?? CommandApplier.defaultStillDuration))
        }
        var clip = Clip(id: clipID, kind: kind, assetID: assetID, name: asset.name,
                        start: quantise(RationalTime.max(.zero, start ?? .zero)), duration: length, sourceStart: source)
        if kind == .image || kind == .video { clip.transform.fit = .contain }
        // Free tracks: if the requested spot is taken on the requested track, fall through to auto placement.
        if let trackID, let ti = project.sequences[s].trackIndex(trackID),
           !project.sequences[s].tracks[ti].kind.isMagnetic, project.sequences[s].tracks[ti].hasOverlap(clip.range) {
            throw EditError.overlap("There is already a clip at that position on the \(project.sequences[s].tracks[ti].name) track.")
        }
        try place(clip, sequence: s, trackID: trackID, index: index)
        return "Add \(asset.name)"
    }

    private mutating func moveClip(clipID: UUID, toTrackID: UUID?, start: RationalTime?, index: Int?) throws -> String {
        let (s, t, c) = try locate(clipID)
        try requireUnlocked(s, t)
        var clip = project.sequences[s].tracks[t].clips[c]
        let targetT: Int
        if let toTrackID {
            guard let found = project.sequences[s].trackIndex(toTrackID) else { throw EditError.trackNotFound(toTrackID) }
            targetT = found
        } else {
            targetT = t
        }
        try requireUnlocked(s, targetT)
        let target = project.sequences[s].tracks[targetT]
        guard target.kind.accepts(clip.kind) else {
            throw EditError.invalid("A \(clip.kind.rawValue) clip cannot go on the \(target.name) track.")
        }
        if target.kind.isMagnetic {
            let sameTrack = targetT == t
            var destination: Int
            if let index {
                destination = index
            } else if let start {
                // Drop position: before the first clip whose midpoint is after the drop point.
                let others = target.clips.filter { $0.id != clipID }
                destination = others.firstIndex { ($0.start + $0.duration.scaled(by: 0.5)) > start } ?? others.count
            } else {
                destination = sameTrack ? c : target.clips.count
            }
            project.sequences[s].tracks[t].clips.remove(at: c)
            let count = project.sequences[s].tracks[targetT].clips.count
            destination = max(0, min(destination, count))
            if !sameTrack { clip.transitionIn = nil }
            project.sequences[s].tracks[targetT].clips.insert(clip, at: destination)
            return "Move clip"
        }
        let newStart = quantise(RationalTime.max(.zero, start ?? clip.start))
        let range = TimeRange(start: newStart, duration: clip.duration)
        if target.hasOverlap(range, excluding: clipID) {
            throw EditError.overlap("There is already a clip at that position on the \(target.name) track.")
        }
        project.sequences[s].tracks[t].clips.remove(at: c)
        clip.start = newStart
        if project.sequences[s].tracks[t].kind.isMagnetic { clip.transitionIn = nil }
        project.sequences[s].tracks[targetT].clips.append(clip)
        return "Move clip"
    }

    private mutating func trimClip(clipID: UUID, edge: TrimEdge, to: RationalTime) throws -> String {
        let (s, t, c) = try locate(clipID)
        try requireUnlocked(s, t)
        var clip = project.sequences[s].tracks[t].clips[c]
        let track = project.sequences[s].tracks[t]
        let target = quantise(to)
        switch edge {
        case .end:
            var length = target - clip.start
            if let available = availableDuration(kind: clip.kind, assetID: clip.assetID, sourceStart: clip.sourceStart, speed: clip.speed) {
                length = RationalTime.min(length, available.floored(toFrame: rate))
            }
            if !track.kind.isMagnetic {
                let next = track.clips.filter { $0.id != clipID && $0.start >= clip.start }.map(\.start).min()
                if let next { length = RationalTime.min(length, next - clip.start) }
            }
            clip.duration = RationalTime.max(oneFrame, length)
        case .start:
            var delta = target - clip.start
            delta = RationalTime.min(delta, clip.duration - oneFrame)
            if clip.usesSourceTiming {
                let headroom = clip.speed == 1 ? clip.sourceStart : clip.sourceStart.scaled(by: 1 / clip.speed)
                delta = RationalTime.max(delta, -(headroom.floored(toFrame: rate)))
            }
            if !track.kind.isMagnetic {
                let previousEnd = track.clips.filter { $0.id != clipID && $0.end <= clip.start }.map(\.end).max() ?? .zero
                delta = RationalTime.max(delta, previousEnd - clip.start)
                clip.start += delta
            }
            clip.duration -= delta
            clip.sourceStart = RationalTime.max(.zero, clip.sourceStart + (clip.speed == 1 ? delta : delta.scaled(by: clip.speed)))
            clip.keyframes = clip.keyframes.map { var k = $0; k.time = (k.time - delta).clamped(.zero, clip.duration); return k }
            shiftTextTiming(&clip, by: -delta)
        }
        clip.audio.fadeIn = clip.audio.fadeIn.clamped(.zero, clip.duration)
        clip.audio.fadeOut = clip.audio.fadeOut.clamped(.zero, clip.duration - clip.audio.fadeIn)
        clip.keyframes = clip.keyframes.map { var k = $0; k.time = k.time.clamped(.zero, clip.duration); return k }
        project.sequences[s].tracks[t].clips[c] = clip
        return "Trim clip"
    }

    private func shiftTextTiming(_ clip: inout Clip, by delta: RationalTime) {
        guard var text = clip.text else { return }
        text.words = text.words.map {
            TimedWord(text: $0.text, start: RationalTime.max(.zero, $0.start + delta), end: RationalTime.max(.zero, $0.end + delta))
        }
        if var lyric = text.lyric {
            lyric.wordTimes = lyric.wordTimes.map { RationalTime.max(.zero, $0 + delta) }
            text.lyric = lyric
        }
        clip.text = text
    }

    private mutating func splitClip(clipID: UUID, at: RationalTime, newClipID: UUID) throws -> String {
        let (s, t, c) = try locate(clipID)
        try requireUnlocked(s, t)
        guard project.locateClip(newClipID) == nil else { throw EditError.invalid("A clip with this identifier already exists.") }
        let original = project.sequences[s].tracks[t].clips[c]
        let cut = quantise(at)
        guard cut > original.start, cut < original.end else {
            throw EditError.invalid("Move the playhead inside the clip to split it.")
        }
        let offset = cut - original.start
        var first = original
        var second = original
        first.duration = offset
        second.id = newClipID
        second.start = cut
        second.duration = original.duration - offset
        second.sourceStart = original.sourceStart + (original.speed == 1 ? offset : offset.scaled(by: original.speed))
        second.transitionIn = nil
        second.linkedClipID = nil
        first.audio.fadeOut = .zero
        second.audio.fadeIn = .zero
        first.audio.fadeIn = original.audio.fadeIn.clamped(.zero, first.duration)
        second.audio.fadeOut = original.audio.fadeOut.clamped(.zero, second.duration)

        // Keyframes: each half keeps its own, plus a boundary keyframe so motion stays continuous.
        var firstFrames: [Keyframe] = []
        var secondFrames: [Keyframe] = []
        for property in AnimatableProperty.allCases where original.hasKeyframes(for: property) {
            let boundary = original.value(of: property, at: offset)
            for frame in original.keyframes where frame.property == property {
                if frame.time < offset {
                    firstFrames.append(frame)
                } else if frame.time > offset {
                    var moved = frame
                    moved.id = UUID(deriving: frame.id, salt: newClipID.uuidString)
                    moved.time = frame.time - offset
                    secondFrames.append(moved)
                }
            }
            firstFrames.append(Keyframe(id: UUID(deriving: clipID, salt: "split-a-\(property.rawValue)-\(newClipID.uuidString)"),
                                        property: property, time: offset, value: boundary))
            secondFrames.append(Keyframe(id: UUID(deriving: clipID, salt: "split-b-\(property.rawValue)-\(newClipID.uuidString)"),
                                         property: property, time: .zero, value: boundary))
        }
        first.keyframes = firstFrames
        second.keyframes = secondFrames

        if var text = original.text, !text.words.isEmpty {
            var a = text, b = text
            a.words = text.words.filter { $0.start < offset }
            b.words = text.words.filter { $0.start >= offset }.map {
                TimedWord(text: $0.text, start: $0.start - offset, end: $0.end - offset)
            }
            if !a.words.isEmpty, !b.words.isEmpty {
                a.string = a.words.map(\.text).joined(separator: " ")
                b.string = b.words.map(\.text).joined(separator: " ")
            }
            text = a
            first.text = a
            second.text = b
        }
        project.sequences[s].tracks[t].clips[c] = first
        project.sequences[s].tracks[t].clips.insert(second, at: c + 1)
        return "Split clip"
    }

    private mutating func detachAudio(clipID: UUID, newClipID: UUID, newTrackID: UUID) throws -> String {
        let (s, t, c) = try locate(clipID)
        try requireUnlocked(s, t)
        let clip = project.sequences[s].tracks[t].clips[c]
        guard clip.kind == .video, let asset = project.asset(clip.assetID), asset.metadata.hasAudio else {
            throw EditError.invalid("This clip has no audio to detach.")
        }
        guard clip.linkedClipID == nil else { throw EditError.invalid("The audio is already detached.") }
        guard project.locateClip(newClipID) == nil else { throw EditError.invalid("A clip with this identifier already exists.") }
        var audio = Clip(id: newClipID, kind: .audio, assetID: clip.assetID, name: clip.name, start: clip.start,
                         duration: clip.duration, sourceStart: clip.sourceStart, speed: clip.speed)
        audio.audio = clip.audio
        audio.audio.muted = false
        audio.linkedClipID = clipID
        project.sequences[s].tracks[t].clips[c].audio.muted = true
        project.sequences[s].tracks[t].clips[c].linkedClipID = newClipID
        if let free = project.sequences[s].tracks.firstIndex(where: { $0.kind == .audio && !$0.locked && !$0.hasOverlap(audio.range) }) {
            project.sequences[s].tracks[free].clips.append(audio)
        } else {
            let number = project.sequences[s].tracks.filter { $0.kind == .audio }.count + 1
            project.sequences[s].tracks.append(Track(id: newTrackID, kind: .audio, name: "Audio \(number)", clips: [audio]))
        }
        return "Detach audio"
    }

    private mutating func setSpeed(clipID: UUID, speed: Double) throws -> String {
        let (s, t, c) = try locate(clipID)
        try requireUnlocked(s, t)
        guard speed.isFinite, CommandApplier.speedRange.contains(speed) else {
            throw EditError.invalid("Speed must be between 0.1× and 100×.")
        }
        var clip = project.sequences[s].tracks[t].clips[c]
        guard clip.usesSourceTiming else { throw EditError.invalid("Speed applies to video and audio clips.") }
        let source = clip.sourceDuration
        let length = RationalTime.max(oneFrame, source.scaled(by: 1 / speed).floored(toFrame: rate))
        let track = project.sequences[s].tracks[t]
        if !track.kind.isMagnetic, track.hasOverlap(TimeRange(start: clip.start, duration: length), excluding: clipID) {
            throw EditError.overlap("Slowing this clip would run into the next clip on the \(track.name) track.")
        }
        let ratio = length.seconds / max(clip.duration.seconds, 1e-9)
        clip.keyframes = clip.keyframes.map { var k = $0; k.time = quantise(k.time.scaled(by: ratio)).clamped(.zero, length); return k }
        clip.speed = speed
        clip.duration = length
        clip.audio.fadeIn = clip.audio.fadeIn.clamped(.zero, length)
        clip.audio.fadeOut = clip.audio.fadeOut.clamped(.zero, length - clip.audio.fadeIn)
        project.sequences[s].tracks[t].clips[c] = clip
        return "Change speed to \(String(format: "%.2g", speed))×"
    }

    // MARK: Beats

    private mutating func cutToBeat(clipIDs: [UUID], every: Int) throws -> String {
        guard every >= 1, every <= 64 else { throw EditError.invalid("Choose a beat interval between 1 and 64.") }
        guard let firstID = clipIDs.first else { throw EditError.invalid("Select clips on the main track to cut to the beat.") }
        let (s, t, _) = try locate(firstID)
        try requireUnlocked(s, t)
        guard project.sequences[s].tracks[t].kind.isMagnetic else {
            throw EditError.invalid("Cut to beat works on the main track.")
        }
        let selected = Set(clipIDs)
        let indices = project.sequences[s].tracks[t].clips.indices.filter { selected.contains(project.sequences[s].tracks[t].clips[$0].id) }
        guard indices.count == clipIDs.count else { throw EditError.invalid("All selected clips must be on the main track.") }
        guard let firstIndex = indices.first, indices == Array(firstIndex..<(firstIndex + indices.count)) else {
            throw EditError.invalid("Select neighbouring clips to cut to the beat.")
        }
        let origin = project.sequences[s].tracks[t].clips[firstIndex].start
        let beats = project.sequences[s].beatTimes
        guard !beats.isEmpty else { throw EditError.invalid("Detect beats first, then cut to the beat.") }
        // Boundaries: the first clip's start, then every Nth beat after it.
        let later = beats.filter { $0 > origin }
        var boundaries: [RationalTime] = [origin]
        var cursor = every - 1
        while cursor < later.count, boundaries.count <= indices.count {
            boundaries.append(later[cursor])
            cursor += every
        }
        guard boundaries.count == indices.count + 1 else {
            throw EditError.invalid("Not enough beats after the first clip: need \(indices.count), found \(boundaries.count - 1).")
        }
        for (offset, index) in indices.enumerated() {
            var clip = project.sequences[s].tracks[t].clips[index]
            let span = quantise(boundaries[offset + 1]) - quantise(boundaries[offset])
            // The next clip's transition overlaps this one, so this clip runs that much longer.
            var overlap = RationalTime.zero
            if index + 1 < project.sequences[s].tracks[t].clips.count,
               let transition = project.sequences[s].tracks[t].clips[index + 1].transitionIn {
                overlap = transition.duration
            }
            var length = span + overlap
            guard length >= oneFrame else { throw EditError.invalid("Beats are too close together for this frame rate.") }
            if let available = availableDuration(kind: clip.kind, assetID: clip.assetID, sourceStart: clip.sourceStart, speed: clip.speed) {
                let limit = available.floored(toFrame: rate)
                if length > limit {
                    throw EditError.invalid("\(clip.name) is too short to reach the next beat. Use a shorter beat interval or a longer clip.")
                }
                length = RationalTime.min(length, limit)
            }
            clip.duration = length
            clip.audio.fadeIn = clip.audio.fadeIn.clamped(.zero, length)
            clip.audio.fadeOut = clip.audio.fadeOut.clamped(.zero, length - clip.audio.fadeIn)
            clip.keyframes = clip.keyframes.map { var k = $0; k.time = k.time.clamped(.zero, length); return k }
            project.sequences[s].tracks[t].clips[index] = clip
        }
        return every == 1 ? "Cut to every beat" : "Cut to every \(every) beats"
    }

    // MARK: Captions

    private mutating func replaceCaptions(sequenceID: UUID?, trackID: UUID, segments: [CaptionSegment], style: TextStyle,
                                          animation: TextAnimation) throws -> String {
        let s = try sequenceIndex(sequenceID)
        guard segments.count <= 20_000 else { throw EditError.invalid("Too many captions (limit 20,000).") }
        let sorted = segments.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var clips: [Clip] = []
        for (index, segment) in sorted.enumerated() {
            let start = quantise(RationalTime.max(.zero, segment.start))
            var end = quantise(segment.end)
            if index + 1 < sorted.count { end = RationalTime.min(end, quantise(sorted[index + 1].start)) }
            if let last = clips.last, start < last.end { continue }
            guard end - start >= oneFrame else { continue }
            let words = segment.words.map {
                TimedWord(text: $0.text, start: RationalTime.max(.zero, $0.start - start),
                          end: RationalTime.max(.zero, $0.end - start))
            }
            let text = TextContent(string: String(segment.text.prefix(2_000)), role: .caption, style: style,
                                   animation: animation, words: words)
            var clip = Clip(id: UUID(deriving: trackID, salt: "caption-\(index)-\(start)"), kind: .text,
                            name: String(segment.text.prefix(40)), start: start, duration: end - start, text: text)
            clip.transform.position = UnitPoint2D(x: 0.5, y: 0.78)
            clips.append(clip)
        }
        if let t = project.sequences[s].trackIndex(trackID) {
            guard project.sequences[s].tracks[t].kind == .caption else { throw EditError.invalid("That is not a caption track.") }
            try requireUnlocked(s, t)
            project.sequences[s].tracks[t].clips = clips
        } else {
            let number = project.sequences[s].tracks.filter { $0.kind == .caption }.count + 1
            project.sequences[s].tracks.append(Track(id: trackID, kind: .caption, name: number == 1 ? "Captions" : "Captions \(number)", clips: clips))
        }
        return clips.isEmpty ? "Clear captions" : "Set \(clips.count) captions"
    }

    // MARK: Comic Studio

    private mutating func withComic<T>(_ body: (inout ComicState) throws -> T) throws -> T {
        guard var comic = project.comic else {
            throw EditError.invalid("Turn on Comic Studio for this project first.")
        }
        let result = try body(&comic)
        project.comic = comic
        return result
    }

    private mutating func withStrip<T>(_ stripID: UUID, _ body: (inout ComicStrip, ComicState) throws -> T) throws -> T {
        try withComic { comic in
            guard let index = comic.strips.firstIndex(where: { $0.id == stripID }) else { throw EditError.stripNotFound(stripID) }
            var strip = comic.strips[index]
            let result = try body(&strip, comic)
            comic.strips[index] = strip
            return result
        }
    }

    private mutating func applyComic(_ command: ComicCommand) throws -> String {
        switch command {
        case .enable(let number, let slug):
            guard number >= 0, number <= 99_999 else { throw EditError.invalid("The comic number must be between 0 and 99999.") }
            if var comic = project.comic {
                comic.number = number
                comic.slug = String(slug.prefix(80))
                project.comic = comic
            } else {
                project.comic = ComicState(number: number, slug: String(slug.prefix(80)))
            }
            return "Set up Comic Studio"

        case .setSynopsis(let synopsis):
            guard synopsis.panelLines.count <= 12 else { throw EditError.invalid("A synopsis holds up to 12 panel lines.") }
            try withComic { $0.synopsis = synopsis }
            return "Edit synopsis"

        case .addStrip(let strip):
            let asset = try requireAsset(strip.assetID)
            guard asset.kind == .image else { throw EditError.invalid("A comic strip must be an image.") }
            try validatePanels(strip.panels)
            try withComic { comic in
                guard comic.strip(strip.id) == nil else { throw EditError.invalid("This strip is already in the project.") }
                comic.strips.append(strip)
            }
            return "Import strip \(asset.name)"

        case .removeStrip(let stripID):
            try withComic { comic in
                guard comic.strip(stripID) != nil else { throw EditError.stripNotFound(stripID) }
                comic.strips.removeAll { $0.id == stripID }
            }
            return "Remove strip"

        case .setPanels(let stripID, let panels, let paperColor):
            try validatePanels(panels)
            try withStrip(stripID) { strip, _ in
                strip.panels = panels
                if let paperColor { strip.paperColor = paperColor }
            }
            return "Set \(panels.count) panels"

        case .setPanelReview(let stripID, let panelID, let review):
            try withStrip(stripID) { strip, _ in
                guard let index = strip.panels.firstIndex(where: { $0.id == panelID }) else { throw EditError.panelNotFound(panelID) }
                var cleaned = review
                cleaned.strangerNote = String(review.strangerNote.prefix(2_000))
                strip.panels[index].review = cleaned
            }
            return "Review panel"

        case .setCheck(let stripID, let itemID, let result):
            try withStrip(stripID) { strip, comic in
                guard comic.checklist.items.contains(where: { $0.id == itemID }) else {
                    throw EditError.invalid("Checklist item '\(itemID)' does not exist.")
                }
                strip.checks[itemID] = CheckResult(status: result.status, reason: String(result.reason.prefix(2_000)))
            }
            return "Answer check \(itemID)"

        case .setChecklist(let checklist, let bannedWords):
            guard !checklist.items.isEmpty, checklist.items.count <= 60 else {
                throw EditError.invalid("A checklist needs between 1 and 60 items.")
            }
            guard Set(checklist.items.map(\.id)).count == checklist.items.count else {
                throw EditError.invalid("Checklist item identifiers must be unique.")
            }
            try withComic { comic in
                comic.checklist = checklist
                comic.bannedWords = bannedWords.map { $0.lowercased() }.filter { !$0.isEmpty }
            }
            return "Edit QA checklist"

        case .approveStrip(let stripID, let approval):
            try withStrip(stripID) { strip, comic in
                let problems = QAGate.approvalBlockers(strip: strip, comic: comic)
                guard problems.isEmpty else { throw EditError.validationFailed(problems) }
                guard approval.qaHash == QAGate.stateHash(strip: strip, checklist: comic.checklist) else {
                    throw EditError.invalid("The review changed while approving. Review the strip again.")
                }
                guard approval.imageHash.count == 64 else { throw EditError.invalid("The approval is missing the image hash.") }
                strip.approval = approval
            }
            return "Approve strip"

        case .revokeApproval(let stripID):
            try withStrip(stripID) { strip, _ in strip.approval = nil }
            return "Revoke approval"

        case .recordRejection(let stripID, let attempt):
            try withStrip(stripID) { strip, _ in
                guard !strip.rejected.contains(where: { $0.id == attempt.id }) else { return }
                strip.rejected.append(attempt)
            }
            return "Record rejected attempt"

        case .setRequireQA(let required):
            try withComic { $0.requireQAForExport = required }
            return required ? "Require QA before export" : "Stop requiring QA"

        case .setMontage(let plan):
            for frame in plan.frames {
                _ = try requireAsset(frame.assetID)
                guard frame.end > frame.start else { throw EditError.invalid("Every montage frame needs a positive length.") }
            }
            try withComic { $0.montage = plan }
            return "Edit montage"

        case .setLyricEdit(let edit):
            guard edit.lines.count <= 2_000 else { throw EditError.invalid("A lyric edit holds up to 2,000 lines.") }
            for line in edit.lines {
                guard line.end > line.start else { throw EditError.invalid("Every lyric line needs an end after its start.") }
                for shot in line.shots { _ = try requireAsset(shot.assetID) }
            }
            if let audio = edit.audioAssetID { _ = try requireAsset(audio) }
            try withComic { $0.lyricEdit = edit }
            return "Edit lyrics"

        case .setEndCard(let endCard):
            guard endCard.duration.isPositive, endCard.duration.seconds <= 30 else {
                throw EditError.invalid("The end card can last up to 30 seconds.")
            }
            try withComic { $0.endCard = endCard }
            return "Edit end card"

        case .setSongNote(let note):
            try withComic { $0.songNote = note }
            return "Edit song note"

        case .setPosting(let draft):
            try withComic { $0.posting = draft }
            return "Edit posting draft"
        }
    }

    private func validatePanels(_ panels: [ComicPanel]) throws {
        guard panels.count <= 64 else { throw EditError.invalid("A strip holds up to 64 panels.") }
        guard Set(panels.map(\.id)).count == panels.count else { throw EditError.invalid("Panel identifiers must be unique.") }
        for panel in panels where !panel.rect.isValid {
            throw EditError.invalid("Every panel must sit inside the strip.")
        }
    }
}
