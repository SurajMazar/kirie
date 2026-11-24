import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ProjectDomain
import UniformTypeIdentifiers

public enum MediaError: Error, Equatable, LocalizedError {
    case missing(String)
    case unreadable(String)
    case unsupported(String, hint: String)
    case tooLarge(String, detail: String)
    case empty(String)
    case decodeFailed(String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "“\(name)” could not be found. It may have been moved or deleted."
        case .unreadable(let name): "“\(name)” cannot be read. Check that Kirie has permission to open it."
        case .unsupported(let name, let hint): "“\(name)” is not a supported media file. \(hint)"
        case .tooLarge(let name, let detail): "“\(name)” is too large to import. \(detail)"
        case .empty(let name): "“\(name)” has no playable picture or sound."
        case .decodeFailed(let name, let detail): "“\(name)” could not be decoded. \(detail)"
        }
    }
}

/// Reads technical metadata from media files. Files are untrusted: sizes and dimensions are
/// validated before anything is decoded at full resolution.
public enum MediaProbe {
    public static let maxDimension = 16_384
    public static let maxDurationSeconds = 24.0 * 3600

    public static func kind(of url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) { return .video }
        return nil
    }

    public static func probe(_ url: URL) async throws -> (kind: MediaKind, metadata: MediaMetadata) {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MediaError.missing(name)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaError.unreadable(name) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw MediaError.empty(name) }
        guard let kind = kind(of: url) else {
            throw MediaError.unsupported(name, hint: "Kirie imports video (MOV, MP4, M4V), audio (WAV, M4A, MP3, AIFF, CAF) and images (PNG, JPEG, HEIC, TIFF, GIF, WebP).")
        }
        switch kind {
        case .image: return (.image, try probeImage(url))
        case .audio, .video: return try await probeTimed(url, expected: kind)
        }
    }

    static func probeImage(_ url: URL) throws -> MediaMetadata {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw MediaError.decodeFailed(name, detail: "The image data is damaged or in an unknown format.")
        }
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { throw MediaError.decodeFailed(name, detail: "The image has no size.") }
        guard width <= maxDimension, height <= maxDimension else {
            throw MediaError.tooLarge(name, detail: "Images can be up to \(maxDimension) pixels on a side; this one is \(width)×\(height).")
        }
        // EXIF orientations 5–8 are rotated a quarter turn.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }
        let profile = properties[kCGImagePropertyProfileName] as? String
        return MediaMetadata(width: width, height: height, colorPrimaries: profile, hasVideo: true)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? String(format: "0x%08X", code) : text
    }

    static func rotationDegrees(_ transform: CGAffineTransform) -> Int {
        let degrees = Int((atan2(Double(transform.b), Double(transform.a)) * 180 / .pi).rounded())
        let normalised = ((degrees % 360) + 360) % 360
        return [0, 90, 180, 270].min { abs($0 - normalised) < abs($1 - normalised) } ?? 0
    }

    static func probeTimed(_ url: URL, expected: MediaKind) async throws -> (kind: MediaKind, metadata: MediaMetadata) {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MediaError.decodeFailed(name, detail: "macOS cannot open this file (\(error.localizedDescription)).")
        }
        var metadata = MediaMetadata()
        guard duration.isNumeric, duration.seconds > 0 else { throw MediaError.empty(name) }
        guard duration.seconds <= maxDurationSeconds else {
            throw MediaError.tooLarge(name, detail: "Clips can be up to 24 hours long.")
        }
        metadata.duration = RationalTime(duration)

        if let track = videoTracks.first {
            let (size, transform, rate, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            metadata.hasVideo = true
            metadata.width = Int(abs(size.width).rounded())
            metadata.height = Int(abs(size.height).rounded())
            metadata.frameRate = Double(rate)
            metadata.rotationDegrees = rotationDegrees(transform)
            guard metadata.width > 0, metadata.height > 0 else { throw MediaError.decodeFailed(name, detail: "The video has no picture size.") }
            guard metadata.width <= maxDimension, metadata.height <= maxDimension else {
                throw MediaError.tooLarge(name, detail: "Video can be up to \(maxDimension) pixels on a side.")
            }
            if let format = formats.first {
                metadata.videoCodec = fourCC(CMFormatDescriptionGetMediaSubType(format))
                let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
                let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                metadata.colorPrimaries = primaries
                metadata.transferFunction = transfer
                metadata.isHDR = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            }
        }
        if let track = audioTracks.first {
            let formats = try await track.load(.formatDescriptions)
            metadata.hasAudio = true
            if let format = formats.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                metadata.sampleRate = basic.mSampleRate
                metadata.audioChannels = Int(basic.mChannelsPerFrame)
                metadata.audioCodec = fourCC(basic.mFormatID)
            }
        }
        guard metadata.hasVideo || metadata.hasAudio else { throw MediaError.empty(name) }
        // A "video" container with only sound is audio; an "audio" type with a picture track is video.
        let kind: MediaKind = metadata.hasVideo ? .video : .audio
        _ = expected
        return (kind, metadata)
    }
}
