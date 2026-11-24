import Foundation

public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case video, audio, image
}

/// Where a media file lives. Source bytes are never stored in project JSON.
public struct MediaReference: Hashable, Sendable, Codable {
    /// Absolute path at import time. May go stale; `relativePath` and relink cover that.
    public var absolutePath: String
    /// Path relative to the `.kirie` package when the file lives inside it (collected projects).
    public var relativePath: String?
    /// Security-scoped bookmark, populated by sandboxed builds.
    public var bookmark: Data?
    public var fileSize: Int64
    /// Fast content fingerprint (size + head + tail SHA-256) used for relink suggestions and dedupe.
    public var fingerprint: String

    public init(absolutePath: String, relativePath: String? = nil, bookmark: Data? = nil, fileSize: Int64 = 0,
                fingerprint: String = "") {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.bookmark = bookmark
        self.fileSize = fileSize
        self.fingerprint = fingerprint
    }

    public var fileName: String { (absolutePath as NSString).lastPathComponent }
}

public struct MediaMetadata: Hashable, Sendable, Codable {
    public var duration: RationalTime
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var videoCodec: String?
    public var audioCodec: String?
    public var audioChannels: Int
    public var sampleRate: Double
    /// Clockwise rotation in degrees needed to display the picture upright (0, 90, 180, 270).
    public var rotationDegrees: Int
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var isHDR: Bool
    public var hasVideo: Bool
    public var hasAudio: Bool

    public init(duration: RationalTime = .zero, width: Int = 0, height: Int = 0, frameRate: Double = 0,
                videoCodec: String? = nil, audioCodec: String? = nil, audioChannels: Int = 0, sampleRate: Double = 0,
                rotationDegrees: Int = 0, colorPrimaries: String? = nil, transferFunction: String? = nil,
                isHDR: Bool = false, hasVideo: Bool = false, hasAudio: Bool = false) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.sampleRate = sampleRate
        self.rotationDegrees = rotationDegrees
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.isHDR = isHDR
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }

    /// Display size after applying rotation metadata.
    public var displayWidth: Int { rotationDegrees % 180 == 0 ? width : height }
    public var displayHeight: Int { rotationDegrees % 180 == 0 ? height : width }
}

/// What the user has told Kirie about their right to export this media.
public enum RightsStatus: String, Sendable, Codable, CaseIterable {
    /// Not declared. Exported normally, with a reminder in the export report.
    case unknown
    /// The user made it or owns it outright.
    case owned
    /// Licensed or royalty-free for the intended use.
    case licensed
    /// A commercial recording the user has no export rights for. Never baked into an export:
    /// Kirie exports silently and writes a song note so the track can be added on the platform.
    case commercialUnlicensed

    public var displayName: String {
        switch self {
        case .unknown: "Not declared"
        case .owned: "Owned"
        case .licensed: "Licensed"
        case .commercialUnlicensed: "Commercial (add in the app)"
        }
    }
}

public struct RightsInfo: Hashable, Sendable, Codable {
    public var status: RightsStatus
    public var title: String?
    public var artist: String?
    public var source: String?
    public var note: String?

    public init(status: RightsStatus = .unknown, title: String? = nil, artist: String? = nil, source: String? = nil,
                note: String? = nil) {
        self.status = status
        self.title = title
        self.artist = artist
        self.source = source
        self.note = note
    }
}

public struct MediaAsset: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: MediaKind
    public var reference: MediaReference
    public var metadata: MediaMetadata
    public var importedAt: Date
    public var rights: RightsInfo
    public var favourite: Bool
    public var rating: Int
    public var keywords: [String]
    /// Optional detected tempo, stored so the UI and CLI agree without re-analysing.
    public var bpm: Double?

    public init(id: UUID = UUID(), name: String, kind: MediaKind, reference: MediaReference,
                metadata: MediaMetadata = MediaMetadata(), importedAt: Date = Date(), rights: RightsInfo = RightsInfo(),
                favourite: Bool = false, rating: Int = 0, keywords: [String] = [], bpm: Double? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.reference = reference
        self.metadata = metadata
        self.importedAt = importedAt.roundedToMilliseconds
        self.rights = rights
        self.favourite = favourite
        self.rating = rating
        self.keywords = keywords
        self.bpm = bpm
    }
}
