import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ProjectDomain
import UniformTypeIdentifiers

/// Small previews for the media browser and timeline. Never decodes full-resolution media just to
/// draw a thumbnail.
public enum Thumbnailer {
    public static func image(for url: URL, kind: MediaKind, maxPixel: Int = 320, at seconds: Double? = nil) async throws -> CGImage {
        switch kind {
        case .image:
            return try stillThumbnail(url, maxPixel: maxPixel)
        case .video:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let wanted = seconds ?? min(1, duration / 3)
            do {
                return try await generator.image(at: CMTime(seconds: max(0, wanted), preferredTimescale: 600)).image
            } catch {
                throw MediaError.decodeFailed(url.lastPathComponent, detail: error.localizedDescription)
            }
        case .audio:
            throw MediaError.unsupported(url.lastPathComponent, hint: "Audio has a waveform instead of a thumbnail.")
        }
    }

    /// Evenly spaced frames for a timeline filmstrip.
    public static func filmstrip(for url: URL, count: Int, maxPixel: Int = 160) async throws -> [(seconds: Double, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var frames: [(Double, CGImage)] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let time = duration * (Double(index) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frames.append((time, image))
            }
        }
        return frames
    }

    public static func stillThumbnail(_ url: URL, maxPixel: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaError.decodeFailed(url.lastPathComponent, detail: "The image data is damaged or in an unknown format.")
        }
        return image
    }

    /// Full-resolution, orientation-corrected image (bounded by `maxPixel`).
    public static func loadImage(_ url: URL, maxPixel: Int = MediaProbe.maxDimension) throws -> CGImage {
        try stillThumbnail(url, maxPixel: maxPixel)
    }

    public static func encode(_ image: CGImage, as type: UTType = .jpeg, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    @discardableResult
    public static func write(_ image: CGImage, to url: URL, as type: UTType = .png, quality: Double = 0.9) -> Bool {
        guard let data = encode(image, as: type, quality: quality) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
