import AppKit
import Foundation
import KirieServices
import MediaServices
import Observation
import Persistence
import ProjectDomain

/// Thumbnails, filmstrips and waveforms, generated off the main thread and cached in memory and in
/// the project package. Views read what is ready and are refreshed when more arrives.
@MainActor
@Observable
final class MediaCache {
    private(set) var thumbnails: [UUID: NSImage] = [:]
    private(set) var filmstrips: [UUID: [(seconds: Double, image: CGImage)]] = [:]
    private(set) var waveforms: [UUID: Waveform] = [:]
    /// Bumped whenever something new is available, so custom-drawn views know to redraw.
    private(set) var generation = 0
    @ObservationIgnored private var requested = Set<String>()

    func reset() {
        thumbnails.removeAll()
        filmstrips.removeAll()
        waveforms.removeAll()
        requested.removeAll()
        generation += 1
    }

    func thumbnail(for asset: MediaAsset, session: ProjectSession) -> NSImage? {
        if let cached = thumbnails[asset.id] { return cached }
        guard asset.kind != .audio, requested.insert("thumb-\(asset.id)").inserted, let url = session.resolver.url(for: asset) else { return nil }
        let cacheURL = session.package.thumbnailsURL.appendingPathComponent("\(asset.id.uuidString).jpg")
        let kind = asset.kind
        Task.detached(priority: .utility) {
            var image: CGImage?
            if let data = try? Data(contentsOf: cacheURL), let source = CGImageSourceCreateWithData(data as CFData, nil) {
                image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            if image == nil, let made = try? await Thumbnailer.image(for: url, kind: kind, maxPixel: 360) {
                image = made
                if let data = Thumbnailer.encode(made, quality: 0.8) { try? data.write(to: cacheURL, options: .atomic) }
            }
            guard let image else { return }
            await MainActor.run {
                self.thumbnails[asset.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                self.generation += 1
            }
        }
        return nil
    }

    func filmstrip(for asset: MediaAsset, session: ProjectSession) -> [(seconds: Double, image: CGImage)]? {
        if let cached = filmstrips[asset.id] { return cached }
        guard asset.kind == .video, requested.insert("strip-\(asset.id)").inserted, let url = session.resolver.url(for: asset) else { return nil }
        let count = max(4, min(40, Int(asset.metadata.duration.seconds / 1.5)))
        Task.detached(priority: .utility) {
            guard let frames = try? await Thumbnailer.filmstrip(for: url, count: count, maxPixel: 120), !frames.isEmpty else { return }
            await MainActor.run {
                self.filmstrips[asset.id] = frames
                self.generation += 1
            }
        }
        return nil
    }

    func waveform(for asset: MediaAsset, session: ProjectSession) -> Waveform? {
        if let cached = waveforms[asset.id] { return cached }
        guard asset.metadata.hasAudio, requested.insert("wave-\(asset.id)").inserted, let url = session.resolver.url(for: asset) else { return nil }
        let cacheURL = session.package.waveformsURL.appendingPathComponent("\(asset.id.uuidString).kwf")
        Task.detached(priority: .utility) {
            var waveform = (try? Data(contentsOf: cacheURL)).flatMap { Waveform(data: $0) }
            if waveform == nil, let made = try? await WaveformGenerator.generate(url) {
                waveform = made
                try? made.data.write(to: cacheURL, options: .atomic)
            }
            guard let waveform else { return }
            await MainActor.run {
                self.waveforms[asset.id] = waveform
                self.generation += 1
            }
        }
        return nil
    }

    /// A still (strip or frame) at display size, loaded synchronously for small counts.
    func loadImage(_ url: URL, maxPixel: Int = 1600) -> NSImage? {
        guard let image = try? Thumbnailer.loadImage(url, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
