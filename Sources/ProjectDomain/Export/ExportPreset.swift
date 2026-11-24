import Foundation

public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case h264, hevc, proRes422

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .proRes422: "ProRes 422"
        }
    }
}

public enum ContainerFormat: String, Sendable, Codable, CaseIterable {
    case mp4, mov
    public var fileExtension: String { rawValue }
}

public struct AudioExportSettings: Hashable, Sendable, Codable {
    public var bitrate: Int
    public var sampleRate: Double
    public var channels: Int

    public init(bitrate: Int = 192_000, sampleRate: Double = 48_000, channels: Int = 2) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct ExportPreset: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var codec: VideoCodec
    public var container: ContainerFormat
    /// Target average video bitrate in bits per second (ignored for ProRes).
    public var videoBitrate: Int
    public var audio: AudioExportSettings
    public var colorSpace: ColorSpaceTag
    /// Replace motion-heavy transitions with dissolves.
    public var reduceMotion: Bool

    public init(id: String, name: String, platform: String, width: Int, height: Int, frameRate: FrameRate = .fps30,
                codec: VideoCodec = .h264, container: ContainerFormat = .mp4, videoBitrate: Int,
                audio: AudioExportSettings = AudioExportSettings(), colorSpace: ColorSpaceTag = .rec709,
                reduceMotion: Bool = false) {
        self.id = id
        self.name = name
        self.platform = platform
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.container = container
        self.videoBitrate = videoBitrate
        self.audio = audio
        self.colorSpace = colorSpace
        self.reduceMotion = reduceMotion
    }

    public static let builtIn: [ExportPreset] = [
        ExportPreset(id: "reels-h264", name: "Instagram Reels", platform: "Instagram", width: 1080, height: 1920,
                     videoBitrate: 12_000_000),
        ExportPreset(id: "reels-hevc", name: "Instagram Reels (HEVC)", platform: "Instagram", width: 1080, height: 1920,
                     codec: .hevc, videoBitrate: 8_000_000),
        ExportPreset(id: "tiktok-h264", name: "TikTok", platform: "TikTok", width: 1080, height: 1920,
                     videoBitrate: 10_000_000),
        ExportPreset(id: "shorts-h264", name: "YouTube Shorts", platform: "YouTube", width: 1080, height: 1920,
                     videoBitrate: 12_000_000),
        ExportPreset(id: "feed-4x5", name: "Feed 4:5", platform: "Instagram", width: 1080, height: 1350,
                     videoBitrate: 10_000_000),
        ExportPreset(id: "square", name: "Square 1:1", platform: "General", width: 1080, height: 1080,
                     videoBitrate: 8_000_000),
        ExportPreset(id: "youtube-1080", name: "YouTube 1080p", platform: "YouTube", width: 1920, height: 1080,
                     videoBitrate: 12_000_000),
        ExportPreset(id: "youtube-4k", name: "YouTube 4K", platform: "YouTube", width: 3840, height: 2160,
                     codec: .hevc, videoBitrate: 45_000_000),
        ExportPreset(id: "master-prores", name: "ProRes 422 master", platform: "Archive", width: 1080, height: 1920,
                     codec: .proRes422, container: .mov, videoBitrate: 0),
    ]

    public static func named(_ id: String) -> ExportPreset? { builtIn.first { $0.id == id } }

    public static func defaultID(for canvas: CanvasSettings) -> String {
        if canvas.width == 1080, canvas.height == 1920 { return "reels-h264" }
        if canvas.width == 1080, canvas.height == 1350 { return "feed-4x5" }
        if canvas.width == 1080, canvas.height == 1080 { return "square" }
        if canvas.width == 1920, canvas.height == 1080 { return "youtube-1080" }
        return "custom"
    }

    /// A preset that matches the canvas exactly, for canvases without a built-in preset.
    public static func matching(_ canvas: CanvasSettings) -> ExportPreset {
        if let preset = named(defaultID(for: canvas)) {
            var matched = preset
            matched.frameRate = canvas.frameRate
            return matched
        }
        let pixels = Double(canvas.width * canvas.height)
        let bitrate = Int((pixels / (1080.0 * 1920.0) * 12_000_000).rounded())
        return ExportPreset(id: "custom", name: "Match canvas", platform: "General", width: canvas.width,
                            height: canvas.height, frameRate: canvas.frameRate,
                            videoBitrate: Swift.max(2_000_000, bitrate), colorSpace: canvas.colorSpace)
    }

    /// Problems that would make the encoder reject or mangle the output.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if width < 16 || height < 16 { problems.append("Resolution must be at least 16×16.") }
        if width % 2 != 0 || height % 2 != 0 { problems.append("Width and height must be even numbers.") }
        if width > 8192 || height > 8192 { problems.append("Resolution above 8192 pixels is not supported.") }
        if codec == .h264, width * height > 4096 * 2304 {
            problems.append("H.264 export is limited to 4096×2304. Use HEVC for larger frames.")
        }
        if frameRate.fps < 1 || frameRate.fps > 120 { problems.append("Frame rate must be between 1 and 120 fps.") }
        if codec != .proRes422, videoBitrate < 100_000 { problems.append("Video bitrate is too low.") }
        if codec == .proRes422, container != .mov { problems.append("ProRes requires a .mov container.") }
        if ![1, 2].contains(audio.channels) { problems.append("Audio must be mono or stereo.") }
        return problems
    }

    /// Rough output size in bytes for a given duration.
    public func estimatedFileSize(duration: RationalTime, hasAudio: Bool) -> Int64 {
        let seconds = Swift.max(0, duration.seconds)
        let video: Double
        if codec == .proRes422 {
            // ProRes 422 is roughly 147 Mbps at 1920×1080 29.97.
            video = 147_000_000 * Double(width * height) / (1920.0 * 1080.0) * frameRate.fps / 29.97
        } else {
            video = Double(videoBitrate)
        }
        let total = video + (hasAudio ? Double(audio.bitrate) : 0)
        return Int64(total * seconds / 8)
    }
}
