import Foundation

public struct Synopsis: Hashable, Sendable, Codable {
    public var premise: String
    /// One short line per panel (2–5 panels).
    public var panelLines: [String]
    public var punchline: String
    public var cast: String

    public init(premise: String = "", panelLines: [String] = [], punchline: String = "", cast: String = "") {
        self.premise = premise
        self.panelLines = panelLines
        self.punchline = punchline
        self.cast = cast
    }
}

public enum ReviewStatus: String, Sendable, Codable, CaseIterable {
    case pass = "PASS"
    case fail = "FAIL"
    case needsReview = "NEEDS_REVIEW"

    public var displayName: String {
        switch self {
        case .pass: "Pass"
        case .fail: "Fail"
        case .needsReview: "Needs review"
        }
    }
}

public struct QAChecklistItem: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var required: Bool

    public init(id: String, title: String, detail: String, required: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.required = required
    }
}

/// The QA checklist is project data: creators can edit, add or remove items.
public struct QAChecklist: Hashable, Sendable, Codable {
    public var items: [QAChecklistItem]

    public init(items: [QAChecklistItem]) { self.items = items }

    /// The A–J comic review checklist. Every answer must be PASS before a strip is approved.
    public static let comicDefault = QAChecklist(items: [
        QAChecklistItem(id: "A", title: "The story reads cold",
                        detail: "Described from the image alone, each panel contains the script's key action. The punchline is the largest, clearest thing in the last panel."),
        QAChecklistItem(id: "B", title: "Every object is accounted for",
                        detail: "Exactly the props the script needs, in the right count. Nothing missing, extra, duplicated or repeated in rows."),
        QAChecklistItem(id: "C", title: "Continuity across panels",
                        detail: "Anything that appears more than once keeps its size, shape, colour, position and design unless the story changes it. Furniture and setting stay put."),
        QAChecklistItem(id: "D", title: "Cause and effect",
                        detail: "Every change between panels has a visible cause, every action shows its consequence, and every turn in the story has a visible trigger."),
        QAChecklistItem(id: "E", title: "Physically possible",
                        detail: "Bodies, objects and actions behave as in the real world: gravity, reach, who holds what, what is visible from where, and which way things face."),
        QAChecklistItem(id: "F", title: "Characters on-model",
                        detail: "Matches the character sheet. Same proportions and head size in every panel, each character once per panel, anatomy correct."),
        QAChecklistItem(id: "G", title: "Style matches the master",
                        detail: "Compared side by side with the style reference: line weight, eye style, proportions, fills, effects and background busyness."),
        QAChecklistItem(id: "H", title: "Text exact",
                        detail: "Only the script's lines, correctly spelled, tails at the right speakers, reading order right."),
        QAChecklistItem(id: "I", title: "Locks",
                        detail: "Every standing rule of the series holds: outfits, colours, signature details."),
        QAChecklistItem(id: "J", title: "Gut check",
                        detail: "It does not look machine-made and it makes sense at a glance."),
    ])

    /// Words that signal a soft pass. If a review note needs one, the item is a FAIL.
    public static let defaultBannedWords = [
        "acceptable", "minor", "borderline", "close enough", "mostly", "fine-ish", "ok-ish",
        "reads well enough", "i'll accept",
    ]
}

public struct CheckResult: Hashable, Sendable, Codable {
    public var status: ReviewStatus
    public var reason: String

    public init(status: ReviewStatus = .needsReview, reason: String = "") {
        self.status = status
        self.reason = reason
    }
}

public struct PanelReview: Hashable, Sendable, Codable {
    public var status: ReviewStatus
    /// One sentence written from the image alone: what a stranger sees.
    public var strangerNote: String

    public init(status: ReviewStatus = .needsReview, strangerNote: String = "") {
        self.status = status
        self.strangerNote = strangerNote
    }
}

public struct ComicPanel: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Panel bounds on the strip, normalised with a top-left origin.
    public var rect: UnitRect
    /// Manual focal point inside the panel (panel-normalised). Nil = use detected subject.
    public var focus: UnitPoint2D?
    /// Detected subject bounds inside the panel (panel-normalised), cached from analysis.
    public var subject: UnitRect?
    public var fit: FitMode
    public var review: PanelReview

    public init(id: UUID = UUID(), rect: UnitRect, focus: UnitPoint2D? = nil, subject: UnitRect? = nil,
                fit: FitMode = .contain, review: PanelReview = PanelReview()) {
        self.id = id
        self.rect = rect
        self.focus = focus
        self.subject = subject
        self.fit = fit
        self.review = review
    }
}

/// Proof that a specific image and a specific set of QA answers were approved.
public struct StripApproval: Hashable, Sendable, Codable {
    /// SHA-256 of the approved image file.
    public var imageHash: String
    /// SHA-256 of the QA state (panels, notes, checklist answers) at approval time.
    public var qaHash: String
    public var approvedBy: String
    public var approvedAt: Date

    public init(imageHash: String, qaHash: String, approvedBy: String, approvedAt: Date = Date()) {
        self.imageHash = imageHash
        self.qaHash = qaHash
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt.roundedToMilliseconds
    }
}

public struct RejectedAttempt: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// File kept in `ComicStudio/rejected/` inside the package.
    public var fileName: String
    public var imageHash: String
    public var failedChecks: [String]
    public var note: String
    public var rejectedAt: Date

    public init(id: UUID = UUID(), fileName: String, imageHash: String, failedChecks: [String], note: String = "",
                rejectedAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.imageHash = imageHash
        self.failedChecks = failedChecks
        self.note = note
        self.rejectedAt = rejectedAt.roundedToMilliseconds
    }
}

public struct ComicStrip: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    /// Panels in reading order.
    public var panels: [ComicPanel]
    /// Gutter / paper colour sampled from the strip; used behind panels that do not fill the canvas.
    public var paperColor: RGBAColor
    /// Checklist answers keyed by item id.
    public var checks: [String: CheckResult]
    public var approval: StripApproval?
    public var rejected: [RejectedAttempt]

    public init(id: UUID = UUID(), assetID: UUID, panels: [ComicPanel] = [], paperColor: RGBAColor = .paper,
                checks: [String: CheckResult] = [:], approval: StripApproval? = nil, rejected: [RejectedAttempt] = []) {
        self.id = id
        self.assetID = assetID
        self.panels = panels
        self.paperColor = paperColor
        self.checks = checks
        self.approval = approval
        self.rejected = rejected
    }
}

public enum ShotCut: String, Sendable, Codable, CaseIterable {
    case ghost, hard, flash, shake, whoosh
}

/// A picture change inside a lyric line: a new image, or a close-up of the same one.
public struct LyricShot: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Song time at which this shot starts.
    public var at: RationalTime
    public var assetID: UUID
    /// 1 = whole picture; 1.6 = close-up.
    public var zoom: Double
    public var focus: UnitPoint2D
    public var cut: ShotCut

    public init(id: UUID = UUID(), at: RationalTime, assetID: UUID, zoom: Double = 1, focus: UnitPoint2D = .center,
                cut: ShotCut = .hard) {
        self.id = id
        self.at = at
        self.assetID = assetID
        self.zoom = zoom
        self.focus = focus
        self.cut = cut
    }
}

public struct LyricLine: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Song time.
    public var start: RationalTime
    public var end: RationalTime
    /// Line text with markup: `*word*` = emphasis, `/` = row break.
    public var text: String
    public var style: LyricStyle
    public var shots: [LyricShot]
    /// Optional per-word reveal times (song time). Missing entries are distributed evenly.
    public var wordTimes: [RationalTime?]
    /// How long the full line holds before it leaves, in seconds (clamped to 0.25–0.6).
    public var hold: Double

    public init(id: UUID = UUID(), start: RationalTime, end: RationalTime, text: String, style: LyricStyle = .verse,
                shots: [LyricShot] = [], wordTimes: [RationalTime?] = [], hold: Double = 0.4) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.style = style
        self.shots = shots
        self.wordTimes = wordTimes
        self.hold = hold
    }
}

public struct LyricEdit: Hashable, Sendable, Codable {
    public var audioAssetID: UUID?
    public var lines: [LyricLine]
    /// Fit for 2:3 artwork on a 9:16 canvas.
    public var fit: FitMode
    public var letterJitter: Bool
    public var stripe: RGBAColor?
    public var chorusFlash: Bool
    public var punchIn: Bool

    public init(audioAssetID: UUID? = nil, lines: [LyricLine] = [], fit: FitMode = .cover, letterJitter: Bool = true,
                stripe: RGBAColor? = nil, chorusFlash: Bool = true, punchIn: Bool = true) {
        self.audioAssetID = audioAssetID
        self.lines = lines
        self.fit = fit
        self.letterJitter = letterJitter
        self.stripe = stripe
        self.chorusFlash = chorusFlash
        self.punchIn = punchIn
    }
}

public enum MontageSection: String, Sendable, Codable, CaseIterable {
    case verse, chorus, peak, final
}

public struct MontageFrame: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    public var start: RationalTime
    public var end: RationalTime
    public var section: MontageSection
    /// Nil = hard cut.
    public var transition: Transition?

    public init(id: UUID = UUID(), assetID: UUID, start: RationalTime, end: RationalTime,
                section: MontageSection = .verse, transition: Transition? = nil) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.end = end
        self.section = section
        self.transition = transition
    }
}

public struct MontagePlan: Hashable, Sendable, Codable {
    public var frames: [MontageFrame]
    public var audioAssetID: UUID?
    public var fit: FitMode

    public init(frames: [MontageFrame] = [], audioAssetID: UUID? = nil, fit: FitMode = .contain) {
        self.frames = frames
        self.audioAssetID = audioAssetID
        self.fit = fit
    }
}

public struct EndCard: Hashable, Sendable, Codable {
    public var enabled: Bool
    public var text: String
    public var duration: RationalTime
    public var background: RGBAColor
    public var textColor: RGBAColor
    public var fontName: String

    public init(enabled: Bool = false, text: String = "", duration: RationalTime = RationalTime(seconds: 2),
                background: RGBAColor = .black, textColor: RGBAColor = .white, fontName: String = "Marker Felt Wide") {
        self.enabled = enabled
        self.text = text
        self.duration = duration
        self.background = background
        self.textColor = textColor
        self.fontName = fontName
    }
}

/// Which song to add on the destination platform when the audio is not exported.
public struct SongNote: Hashable, Sendable, Codable {
    public var title: String
    public var artist: String
    /// For example "start at the chorus, 0:45".
    public var section: String

    public init(title: String = "", artist: String = "", section: String = "") {
        self.title = title
        self.artist = artist
        self.section = section
    }

    public var isEmpty: Bool { title.isEmpty && artist.isEmpty && section.isEmpty }
}

public struct PostingDraft: Hashable, Sendable, Codable {
    public var caption: String
    public var pinnedComment: String
    public var songShortlist: [String]

    public init(caption: String = "", pinnedComment: String = "", songShortlist: [String] = []) {
        self.caption = caption
        self.pinnedComment = pinnedComment
        self.songShortlist = songShortlist
    }
}

/// Comic Studio state for a project.
public struct ComicState: Hashable, Sendable, Codable {
    public var number: Int
    public var slug: String
    public var synopsis: Synopsis
    public var strips: [ComicStrip]
    public var checklist: QAChecklist
    public var bannedWords: [String]
    /// When true, export is blocked until every strip has a current approval.
    public var requireQAForExport: Bool
    public var attemptLimit: Int
    public var montage: MontagePlan
    public var lyricEdit: LyricEdit
    public var endCard: EndCard
    public var songNote: SongNote
    public var posting: PostingDraft

    public init(number: Int = 1, slug: String = "untitled", synopsis: Synopsis = Synopsis(), strips: [ComicStrip] = [],
                checklist: QAChecklist = .comicDefault, bannedWords: [String] = QAChecklist.defaultBannedWords,
                requireQAForExport: Bool = true, attemptLimit: Int = 3, montage: MontagePlan = MontagePlan(),
                lyricEdit: LyricEdit = LyricEdit(), endCard: EndCard = EndCard(), songNote: SongNote = SongNote(),
                posting: PostingDraft = PostingDraft()) {
        self.number = number
        self.slug = slug
        self.synopsis = synopsis
        self.strips = strips
        self.checklist = checklist
        self.bannedWords = bannedWords
        self.requireQAForExport = requireQAForExport
        self.attemptLimit = attemptLimit
        self.montage = montage
        self.lyricEdit = lyricEdit
        self.endCard = endCard
        self.songNote = songNote
        self.posting = posting
    }

    /// `NNN_name` folder convention.
    public var folderName: String {
        let cleaned = slug.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let collapsed = String(cleaned).split(separator: "_").joined(separator: "_")
        return String(format: "%03d_%@", Swift.max(0, number), collapsed.isEmpty ? "untitled" : collapsed)
    }

    public func strip(_ id: UUID) -> ComicStrip? { strips.first { $0.id == id } }
}
