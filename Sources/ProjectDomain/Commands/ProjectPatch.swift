import Foundation

/// A serialisable, reversible description of a project change: the new values of every top-level
/// component that differs. Undo and redo each store one patch, so history never relies on closures.
public struct ProjectPatch: Codable, Sendable, Equatable {
    public struct SequenceChange: Codable, Sendable, Equatable {
        public var id: UUID
        /// Nil means the sequence is removed.
        public var value: Sequence?
    }

    public struct ComicChange: Codable, Sendable, Equatable {
        public var value: ComicState?
    }

    public var name: String?
    public var canvas: CanvasSettings?
    public var exportPresetID: String?
    public var assets: [MediaAsset]?
    public var sequences: [SequenceChange] = []
    public var sequenceOrder: [UUID]?
    public var activeSequenceID: UUID?
    public var comic: ComicChange?
    public var modifiedAt: Date?

    public init() {}

    /// The patch that turns `a` into `b`.
    public static func diff(from a: Project, to b: Project) -> ProjectPatch {
        var patch = ProjectPatch()
        if a.name != b.name { patch.name = b.name }
        if a.canvas != b.canvas { patch.canvas = b.canvas }
        if a.exportPresetID != b.exportPresetID { patch.exportPresetID = b.exportPresetID }
        if a.assets != b.assets { patch.assets = b.assets }
        if a.activeSequenceID != b.activeSequenceID { patch.activeSequenceID = b.activeSequenceID }
        if a.comic != b.comic { patch.comic = ComicChange(value: b.comic) }
        if a.modifiedAt != b.modifiedAt { patch.modifiedAt = b.modifiedAt }

        let before = Dictionary(a.sequences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(b.sequences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for sequence in b.sequences where before[sequence.id] != sequence {
            patch.sequences.append(SequenceChange(id: sequence.id, value: sequence))
        }
        for sequence in a.sequences where after[sequence.id] == nil {
            patch.sequences.append(SequenceChange(id: sequence.id, value: nil))
        }
        if a.sequences.map(\.id) != b.sequences.map(\.id) { patch.sequenceOrder = b.sequences.map(\.id) }
        return patch
    }

    public func apply(to project: inout Project) {
        if let name { project.name = name }
        if let canvas { project.canvas = canvas }
        if let exportPresetID { project.exportPresetID = exportPresetID }
        if let assets { project.assets = assets }
        for change in sequences {
            if let value = change.value {
                if let index = project.sequenceIndex(change.id) {
                    project.sequences[index] = value
                } else {
                    project.sequences.append(value)
                }
            } else {
                project.sequences.removeAll { $0.id == change.id }
            }
        }
        if let sequenceOrder {
            let lookup = Dictionary(project.sequences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = sequenceOrder.compactMap { lookup[$0] }
            let leftovers = project.sequences.filter { !sequenceOrder.contains($0.id) }
            project.sequences = ordered + leftovers
        }
        if let activeSequenceID { project.activeSequenceID = activeSequenceID }
        if let comic { project.comic = comic.value }
        if let modifiedAt { project.modifiedAt = modifiedAt }
    }

    public var events: [DomainEvent] {
        var events: [DomainEvent] = []
        if name != nil || exportPresetID != nil { events.append(.projectInfoChanged) }
        if canvas != nil { events.append(.canvasChanged) }
        if assets != nil { events.append(.assetsChanged) }
        if sequenceOrder != nil || activeSequenceID != nil { events.append(.sequenceListChanged) }
        events.append(contentsOf: sequences.map { .sequenceChanged($0.id) })
        if comic != nil { events.append(.comicChanged) }
        return events
    }

    /// True when nothing but the modification date differs.
    public var isEmpty: Bool {
        name == nil && canvas == nil && exportPresetID == nil && assets == nil && sequences.isEmpty
            && sequenceOrder == nil && activeSequenceID == nil && comic == nil
    }
}

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var envelope: CommandEnvelope
    /// Restores the state before the command.
    public var undo: ProjectPatch
    /// Re-applies the command's result.
    public var redo: ProjectPatch
    public var coalesceKey: String?

    public var id: UUID { envelope.id }
    public var label: String { envelope.label }
}

public struct CommandOutcome: Sendable {
    public let entry: HistoryEntry
    public let events: [DomainEvent]
}
