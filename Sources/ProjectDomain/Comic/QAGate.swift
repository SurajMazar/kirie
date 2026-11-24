import CryptoKit
import Foundation

public enum StripLockState: String, Sendable, Codable {
    /// Approved, and both the image and the review still match the approval.
    case approved
    /// Never approved.
    case notApproved
    /// The image changed after approval.
    case staleImage
    /// Panels, notes or checklist answers changed after approval.
    case staleReview
    /// The source image cannot be read, so the approval cannot be verified.
    case unverifiable
}

public struct StripLockStatus: Hashable, Sendable, Codable {
    public var stripID: UUID
    public var state: StripLockState
    public var message: String
}

public struct ExportLockStatus: Hashable, Sendable, Codable {
    public var isLocked: Bool
    public var strips: [StripLockStatus]

    public var reasons: [String] { strips.filter { $0.state != .approved }.map(\.message) }
    public static let unlocked = ExportLockStatus(isLocked: false, strips: [])
}

/// The Comic Studio QA gate: review completeness, approval hashing and the export lock.
public enum QAGate {
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of everything a reviewer signed off on. Any change to panels, notes or answers changes it.
    public static func stateHash(strip: ComicStrip, checklist: QAChecklist) -> String {
        var lines: [String] = ["strip:\(strip.id.uuidString)", "asset:\(strip.assetID.uuidString)"]
        for (index, panel) in strip.panels.enumerated() {
            let r = panel.rect
            lines.append(String(format: "panel:%d:%@:%.6f,%.6f,%.6f,%.6f:%@:%@", index, panel.id.uuidString,
                                r.x, r.y, r.width, r.height, panel.review.status.rawValue, panel.review.strangerNote))
        }
        for item in checklist.items.sorted(by: { $0.id < $1.id }) {
            let result = strip.checks[item.id] ?? CheckResult()
            lines.append("check:\(item.id):\(item.title):\(item.required):\(result.status.rawValue):\(result.reason)")
        }
        return digest(lines.joined(separator: "\n"))
    }

    /// Banned words found in a review note (case-insensitive, whole phrase).
    public static func lintBannedWords(_ text: String, banned: [String]) -> [String] {
        let lowered = text.lowercased()
        return banned.filter { !$0.isEmpty && lowered.contains($0.lowercased()) }
    }

    /// Everything that stops a strip from being approved right now. Empty means it can be approved.
    public static func approvalBlockers(strip: ComicStrip, comic: ComicState) -> [String] {
        var problems: [String] = []
        if strip.panels.isEmpty { problems.append("Detect or draw the panels first.") }
        for (index, panel) in strip.panels.enumerated() {
            let label = "Panel \(index + 1)"
            switch panel.review.status {
            case .pass: break
            case .fail: problems.append("\(label) is marked FAIL.")
            case .needsReview: problems.append("\(label) has not been reviewed.")
            }
            if panel.review.strangerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("\(label) needs a note describing what a stranger sees.")
            }
            let banned = lintBannedWords(panel.review.strangerNote, banned: comic.bannedWords)
            if !banned.isEmpty {
                problems.append("\(label) note uses \(banned.map { "“\($0)”" }.joined(separator: ", ")). If it needs that word, it is a FAIL.")
            }
        }
        for item in comic.checklist.items {
            let result = strip.checks[item.id] ?? CheckResult()
            if item.required, result.status != .pass {
                problems.append("Check \(item.id) (\(item.title)) is \(result.status == .fail ? "FAIL" : "not answered").")
            }
            let banned = lintBannedWords(result.reason, banned: comic.bannedWords)
            if !banned.isEmpty {
                problems.append("Check \(item.id) uses \(banned.map { "“\($0)”" }.joined(separator: ", ")). If it needs that word, it is a FAIL.")
            }
        }
        return problems
    }

    /// Evaluates the export lock. `imageHashes` maps asset id → SHA-256 of the file on disk right now;
    /// a missing entry means the file could not be read.
    public static func exportLock(project: Project, imageHashes: [UUID: String]) -> ExportLockStatus {
        guard let comic = project.comic, comic.requireQAForExport, !comic.strips.isEmpty else { return .unlocked }
        var statuses: [StripLockStatus] = []
        for (index, strip) in comic.strips.enumerated() {
            let name = project.asset(strip.assetID)?.name ?? "Strip \(index + 1)"
            guard let approval = strip.approval else {
                statuses.append(StripLockStatus(stripID: strip.id, state: .notApproved,
                                                message: "\(name) has not passed QA."))
                continue
            }
            guard let current = imageHashes[strip.assetID] else {
                statuses.append(StripLockStatus(stripID: strip.id, state: .unverifiable,
                                                message: "\(name): the image file is missing, so its approval cannot be verified."))
                continue
            }
            if current != approval.imageHash {
                statuses.append(StripLockStatus(stripID: strip.id, state: .staleImage,
                                                message: "\(name) changed after it was approved. Review it again."))
            } else if stateHash(strip: strip, checklist: comic.checklist) != approval.qaHash {
                statuses.append(StripLockStatus(stripID: strip.id, state: .staleReview,
                                                message: "\(name): the review changed after approval. Approve it again."))
            } else {
                statuses.append(StripLockStatus(stripID: strip.id, state: .approved, message: "\(name) is approved."))
            }
        }
        return ExportLockStatus(isLocked: statuses.contains { $0.state != .approved }, strips: statuses)
    }
}
