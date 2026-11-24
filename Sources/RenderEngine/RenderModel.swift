import AVFoundation
import CoreImage
import Foundation
import MediaServices
import ProjectDomain

/// Finds the file behind a media asset. Implemented by the project package in the app and CLI.
public protocol MediaResolving: Sendable {
    func url(for asset: MediaAsset) -> URL?
}

public struct ClosureMediaResolver: MediaResolving {
    private let body: @Sendable (MediaAsset) -> URL?
    public init(_ body: @escaping @Sendable (MediaAsset) -> URL?) { self.body = body }
    public func url(for asset: MediaAsset) -> URL? { body(asset) }
}

public struct RenderOptions: Sendable, Equatable {
    /// Swap motion-heavy transitions for dissolves.
    public var reduceMotion: Bool
    /// Leave out audio the user has marked as commercial without export rights.
    public var excludeUnlicensedAudio: Bool
    /// Leave out all audio (silent export).
    public var silent: Bool

    public init(reduceMotion: Bool = false, excludeUnlicensedAudio: Bool = true, silent: Bool = false) {
        self.reduceMotion = reduceMotion
        self.excludeUnlicensedAudio = excludeUnlicensedAudio
        self.silent = silent
    }
}

enum LayerSource {
    /// Frames arrive from AVFoundation on this composition track.
    case video(trackID: CMPersistentTrackID, rotation: Int)
    case image(URL)
    case text
    case solid(RGBAColor)
    /// The media file is missing; a placeholder is drawn.
    case offline(name: String)
}

struct RenderLayer {
    let clip: Clip
    let source: LayerSource
}

struct RenderTrack {
    let kind: TrackKind
    /// Sorted by start.
    let layers: [RenderLayer]
}

/// Immutable snapshot of everything the renderer needs for one sequence. Shared by preview and export
/// so both produce the same picture.
public final class RenderModel: @unchecked Sendable {
    /// Size of the output frames.
    public let outputSize: CGSize
    /// Project canvas, the coordinate system clips are positioned in.
    public let canvasSize: CGSize
    public let background: RGBAColor
    public let frameRate: FrameRate
    public let duration: RationalTime
    public let options: RenderOptions
    let tracks: [RenderTrack]
    let images: ImageProvider

    init(outputSize: CGSize, canvasSize: CGSize, background: RGBAColor, frameRate: FrameRate, duration: RationalTime,
         options: RenderOptions, tracks: [RenderTrack], images: ImageProvider) {
        self.outputSize = outputSize
        self.canvasSize = canvasSize
        self.background = background
        self.frameRate = frameRate
        self.duration = duration
        self.options = options
        self.tracks = tracks
        self.images = images
    }

    /// Scale from canvas pixels to output pixels (canvas is fitted inside the output).
    var fitScale: CGFloat {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return min(outputSize.width / canvasSize.width, outputSize.height / canvasSize.height)
    }

    /// The canvas area inside the output frame, in output pixels.
    var canvasRect: CGRect {
        let size = CGSize(width: canvasSize.width * fitScale, height: canvasSize.height * fitScale)
        return CGRect(x: (outputSize.width - size.width) / 2, y: (outputSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Text sizes are authored against a 1080-pixel-wide canvas.
    var textScale: CGFloat { canvasRect.width / 1080 }
}

/// Loads and caches still images as CIImages, bounded in size and memory.
final class ImageProvider: @unchecked Sendable {
    private let cache = NSCache<NSString, CIImage>()
    private let maxPixel: Int

    init(maxPixel: Int) {
        self.maxPixel = max(256, min(MediaProbe.maxDimension, maxPixel))
        cache.countLimit = 48
    }

    func image(at url: URL) -> CIImage? {
        // Include the modification date so an image replaced on disk is picked up.
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let decoded = try? Thumbnailer.loadImage(url, maxPixel: maxPixel) else { return nil }
        let image = CIImage(cgImage: decoded)
        cache.setObject(image, forKey: key)
        return image
    }
}

extension RGBAColor {
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()) ?? CIColor(red: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
