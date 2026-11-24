import Foundation

public enum TrimEdge: String, Sendable, Codable {
    case start, end
}

/// A caption in absolute timeline time.
public struct CaptionSegment: Hashable, Sendable, Codable {
    public var start: RationalTime
    public var end: RationalTime
    public var text: String
    /// Optional word timing in absolute timeline time.
    public var words: [TimedWord]

    public init(start: RationalTime, end: RationalTime, text: String, words: [TimedWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// Every change to a project is one of these. The UI, undo/redo, the CLI, MCP and AI proposals all
/// submit the same typed, serialisable commands; nothing mutates project state any other way.
///
/// New objects carry their identifiers in the command so replaying a command log is deterministic.
public enum EditCommand: Codable, Sendable, Equatable {
    // Project
    case renameProject(name: String)
    case setCanvas(canvas: CanvasSettings)
    case setExportPreset(presetID: String)

    // Assets
    case importAssets(assets: [MediaAsset])
    case removeAsset(assetID: UUID)
    case updateAssetInfo(assetID: UUID, name: String?, rights: RightsInfo?, favourite: Bool?, rating: Int?,
                         keywords: [String]?, bpm: Double?)
    case relinkAsset(assetID: UUID, reference: MediaReference)

    // Sequences
    case addSequence(sequence: Sequence, activate: Bool)
    case replaceSequence(sequence: Sequence)
    case removeSequence(sequenceID: UUID)
    case setActiveSequence(sequenceID: UUID)
    case renameSequence(sequenceID: UUID, name: String)

    // Tracks
    case addTrack(sequenceID: UUID?, trackID: UUID, kind: TrackKind, name: String?, index: Int?)
    case removeTrack(trackID: UUID)
    case setTrackState(trackID: UUID, muted: Bool?, hidden: Bool?, locked: Bool?, gain: Double?, name: String?)

    // Clips
    case addClip(sequenceID: UUID?, clipID: UUID, assetID: UUID, trackID: UUID?, start: RationalTime?,
                 sourceStart: RationalTime?, duration: RationalTime?, index: Int?)
    case insertClip(sequenceID: UUID?, trackID: UUID?, clip: Clip, index: Int?)
    case removeClips(clipIDs: [UUID], ripple: Bool)
    case moveClip(clipID: UUID, toTrackID: UUID?, start: RationalTime?, index: Int?)
    case trimClip(clipID: UUID, edge: TrimEdge, to: RationalTime)
    case splitClip(clipID: UUID, at: RationalTime, newClipID: UUID)
    case duplicateClip(clipID: UUID, newClipID: UUID)
    case renameClip(clipID: UUID, name: String)
    case setTransform(clipID: UUID, transform: ClipTransform)
    case setKeyframe(clipID: UUID, keyframe: Keyframe)
    case removeKeyframe(clipID: UUID, keyframeID: UUID)
    case clearKeyframes(clipID: UUID, property: AnimatableProperty?)
    case setTransition(clipID: UUID, transition: Transition?)
    case setClipAudio(clipID: UUID, audio: ClipAudio)
    case detachAudio(clipID: UUID, newClipID: UUID, newTrackID: UUID)
    case setSpeed(clipID: UUID, speed: Double)
    case setText(clipID: UUID, text: TextContent)
    case setLook(clipID: UUID, color: ColorAdjust, filters: [AppliedFilter], blendMode: BlendMode, mask: ClipMask?,
                 chromaKey: ChromaKey?)
    case closeGaps(trackID: UUID)

    // Markers and beats
    case addMarkers(sequenceID: UUID?, markers: [Marker])
    case removeMarkers(markerIDs: [UUID])
    case moveMarker(markerID: UUID, to: RationalTime)
    case replaceBeatMarkers(sequenceID: UUID?, markers: [Marker])
    case cutToBeat(clipIDs: [UUID], every: Int)

    // Captions
    case replaceCaptions(sequenceID: UUID?, trackID: UUID, segments: [CaptionSegment], style: TextStyle,
                         animation: TextAnimation)

    // Comic Studio
    case comic(command: ComicCommand)

    /// Whether applying this command depends on other clips already being laid out.
    var readsLayout: Bool {
        switch self {
        case .importAssets, .updateAssetInfo, .relinkAsset, .renameProject, .setExportPreset, .addClip, .insertClip, .addMarkers, .comic: false
        default: true
        }
    }

    /// Stable machine name (the JSON key).
    public var name: String {
        Mirror(reflecting: self).children.first?.label ?? "unknown"
    }
}

public enum ComicCommand: Codable, Sendable, Equatable {
    case enable(number: Int, slug: String)
    case setSynopsis(synopsis: Synopsis)
    case addStrip(strip: ComicStrip)
    case removeStrip(stripID: UUID)
    /// Detected or hand-corrected panels in reading order ("apply comic layout").
    case setPanels(stripID: UUID, panels: [ComicPanel], paperColor: RGBAColor?)
    case setPanelReview(stripID: UUID, panelID: UUID, review: PanelReview)
    case setCheck(stripID: UUID, itemID: String, result: CheckResult)
    case setChecklist(checklist: QAChecklist, bannedWords: [String])
    case approveStrip(stripID: UUID, approval: StripApproval)
    case revokeApproval(stripID: UUID)
    case recordRejection(stripID: UUID, attempt: RejectedAttempt)
    case setRequireQA(required: Bool)
    case setMontage(plan: MontagePlan)
    case setLyricEdit(edit: LyricEdit)
    case setEndCard(endCard: EndCard)
    case setSongNote(note: SongNote)
    case setPosting(draft: PostingDraft)
}

public enum CommandActor: Codable, Sendable, Equatable {
    case user
    case cli
    case mcp(client: String)
    case ai(provider: String, model: String)
    case system

    public var label: String {
        switch self {
        case .user: "user"
        case .cli: "cli"
        case .mcp(let client): "mcp:\(client)"
        case .ai(let provider, let model): "ai:\(provider)/\(model)"
        case .system: "system"
        }
    }
}

public struct CommandEnvelope: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var actor: CommandActor
    public var schemaVersion: Int
    public var label: String
    public var commands: [EditCommand]

    public init(id: UUID = UUID(), timestamp: Date = Date(), actor: CommandActor = .user,
                schemaVersion: Int = SchemaVersion.current, label: String, commands: [EditCommand]) {
        self.id = id
        self.timestamp = timestamp.roundedToMilliseconds
        self.actor = actor
        self.schemaVersion = schemaVersion
        self.label = label
        self.commands = commands
    }
}

public enum EditError: Error, Equatable, LocalizedError, Sendable {
    case clipNotFound(UUID)
    case trackNotFound(UUID)
    case assetNotFound(UUID)
    case sequenceNotFound(UUID)
    case markerNotFound(UUID)
    case stripNotFound(UUID)
    case panelNotFound(UUID)
    case trackLocked(String)
    case overlap(String)
    case assetInUse(String)
    case invalid(String)
    case validationFailed([String])
    case nothingToUndo
    case nothingToRedo

    public var errorDescription: String? {
        switch self {
        case .clipNotFound(let id): "Clip \(id.uuidString) was not found."
        case .trackNotFound(let id): "Track \(id.uuidString) was not found."
        case .assetNotFound(let id): "Media \(id.uuidString) was not found in the project."
        case .sequenceNotFound(let id): "Timeline \(id.uuidString) was not found."
        case .markerNotFound(let id): "Marker \(id.uuidString) was not found."
        case .stripNotFound(let id): "Comic strip \(id.uuidString) was not found."
        case .panelNotFound(let id): "Panel \(id.uuidString) was not found."
        case .trackLocked(let name): "The \(name) track is locked. Unlock it to edit."
        case .overlap(let message): message
        case .assetInUse(let name): "\(name) is used on a timeline. Remove those clips first."
        case .invalid(let message): message
        case .validationFailed(let problems): "The edit was rejected: " + problems.joined(separator: " ")
        case .nothingToUndo: "Nothing to undo."
        case .nothingToRedo: "Nothing to redo."
        }
    }
}

/// What changed, for observers that refresh selectively.
public enum DomainEvent: Hashable, Sendable {
    case projectInfoChanged
    case canvasChanged
    case assetsChanged
    case sequenceChanged(UUID)
    case sequenceListChanged
    case comicChanged
}
