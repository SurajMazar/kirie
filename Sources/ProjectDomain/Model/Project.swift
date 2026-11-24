import Foundation

/// The whole editable document. Serialised to `project.json` inside a `.kirie` package.
public struct Project: Hashable, Sendable, Codable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var canvas: CanvasSettings
    public var assets: [MediaAsset]
    public var sequences: [Sequence]
    public var activeSequenceID: UUID
    /// Present once the project uses Comic Studio.
    public var comic: ComicState?
    public var exportPresetID: String

    public init(id: UUID = UUID(), name: String, canvas: CanvasSettings, createdAt: Date = Date()) {
        let sequence = Sequence()
        self.schemaVersion = SchemaVersion.current
        self.id = id
        self.name = name
        self.createdAt = createdAt.roundedToMilliseconds
        self.modifiedAt = createdAt.roundedToMilliseconds
        self.canvas = canvas
        self.assets = []
        self.sequences = [sequence]
        self.activeSequenceID = sequence.id
        self.comic = nil
        self.exportPresetID = ExportPreset.defaultID(for: canvas)
    }

    public func asset(_ id: UUID?) -> MediaAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }

    public func sequenceIndex(_ id: UUID) -> Int? { sequences.firstIndex { $0.id == id } }
    public func sequence(_ id: UUID) -> Sequence? { sequences.first { $0.id == id } }

    public var activeSequence: Sequence {
        sequence(activeSequenceID) ?? sequences.first ?? Sequence()
    }

    /// Finds a clip anywhere in the project.
    public func locateClip(_ clipID: UUID) -> (sequence: Int, track: Int, clip: Int)? {
        for (si, sequence) in sequences.enumerated() {
            if let hit = sequence.locate(clipID) { return (si, hit.track, hit.clip) }
        }
        return nil
    }

    /// True when any clip in any sequence uses the asset.
    public func isAssetInUse(_ id: UUID) -> Bool {
        sequences.contains { $0.allClips.contains { $0.assetID == id } }
            || (comic?.strips.contains { $0.assetID == id } ?? false)
    }
}
