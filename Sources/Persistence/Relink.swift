import Foundation
import ProjectDomain

public struct RelinkCandidate: Sendable, Equatable {
    public var url: URL
    /// Higher is better. 10 = same content fingerprint.
    public var score: Int
    public var reasons: [String]
}

/// Finds likely replacements for missing media. Suggestions only: nothing is relinked until the
/// user (or an explicit command) confirms.
public enum RelinkFinder {
    public static func candidates(for asset: MediaAsset, in directory: URL, maxFiles: Int = 20_000) -> [RelinkCandidate] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let wantedName = asset.reference.fileName.lowercased()
        let wantedExtension = (wantedName as NSString).pathExtension
        var results: [RelinkCandidate] = []
        var visited = 0
        for case let file as URL in enumerator {
            visited += 1
            if visited > maxFiles { break }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let name = file.lastPathComponent.lowercased()
            let sameName = name == wantedName
            let sameSize = asset.reference.fileSize > 0 && Int64(values?.fileSize ?? -1) == asset.reference.fileSize
            guard sameName || (sameSize && (name as NSString).pathExtension == wantedExtension) else { continue }
            var score = 0
            var reasons: [String] = []
            if sameName { score += 3; reasons.append("same name") }
            if sameSize { score += 2; reasons.append("same size") }
            if sameSize, !asset.reference.fingerprint.isEmpty,
               let print = try? FileHasher.fingerprint(of: file), print.fingerprint == asset.reference.fingerprint {
                score += 5
                reasons.append("same content")
            }
            results.append(RelinkCandidate(url: file, score: score, reasons: reasons))
        }
        return results.sorted { $0.score == $1.score ? $0.url.path < $1.url.path : $0.score > $1.score }
    }
}
