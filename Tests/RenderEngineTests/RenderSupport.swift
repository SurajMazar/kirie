import AVFoundation
import CoreGraphics
import Foundation
import MediaServices
import ProjectDomain
@testable import RenderEngine

func renderScratch(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kirie-render-\(safe)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func t(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

let pathResolver = ClosureMediaResolver { asset in
    FileManager.default.fileExists(atPath: asset.reference.absolutePath) ? URL(fileURLWithPath: asset.reference.absolutePath) : nil
}

func importAsset(_ url: URL, rights: RightsStatus = .unknown) async throws -> MediaAsset {
    let (kind, metadata) = try await MediaProbe.probe(url)
    return MediaAsset(name: url.lastPathComponent, kind: kind, reference: MediaReference(absolutePath: url.path), metadata: metadata,
                      rights: RightsInfo(status: rights, title: rights == .commercialUnlicensed ? "Golden Hour" : nil,
                                         artist: rights == .commercialUnlicensed ? "Some Artist" : nil))
}

struct Pixel: CustomStringConvertible {
    var r: Double, g: Double, b: Double, a: Double
    var description: String { String(format: "(%.2f, %.2f, %.2f, %.2f)", r, g, b, a) }
    func isClose(to other: (Double, Double, Double), tolerance: Double = 0.1) -> Bool {
        abs(r - other.0) <= tolerance && abs(g - other.1) <= tolerance && abs(b - other.2) <= tolerance
    }
}

/// Reads pixels with a top-left origin, in normalised coordinates.
struct Bitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &storage, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = storage
    }

    func pixel(_ x: Double, _ y: Double) -> Pixel {
        let px = max(0, min(width - 1, Int(x * Double(width)))), py = max(0, min(height - 1, Int(y * Double(height))))
        let offset = (py * width + px) * 4
        return Pixel(r: Double(bytes[offset]) / 255, g: Double(bytes[offset + 1]) / 255, b: Double(bytes[offset + 2]) / 255, a: Double(bytes[offset + 3]) / 255)
    }

    /// Fraction of pixels in a normalised region that differ clearly from `color`.
    func coverage(in region: CGRect, differingFrom color: (Double, Double, Double), threshold: Double = 0.12) -> Double {
        let x0 = Int(region.minX * Double(width)), x1 = Int(region.maxX * Double(width))
        let y0 = Int(region.minY * Double(height)), y1 = Int(region.maxY * Double(height))
        var different = 0, total = 0
        for y in stride(from: max(0, y0), to: min(height, y1), by: 2) {
            for x in stride(from: max(0, x0), to: min(width, x1), by: 2) {
                let offset = (y * width + x) * 4
                let dr = abs(Double(bytes[offset]) / 255 - color.0), dg = abs(Double(bytes[offset + 1]) / 255 - color.1)
                let db = abs(Double(bytes[offset + 2]) / 255 - color.2)
                if max(dr, dg, db) > threshold { different += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(different) / Double(total)
    }
}

func frame(of url: URL, at seconds: Double) async throws -> Bitmap {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    return Bitmap(image)!
}

/// RMS level of a stretch of an exported file's audio.
func audioLevel(of url: URL, from start: Double, to end: Double) async throws -> Double {
    let samples = try await AudioDecoder.decodeMono(url, sampleRate: 8_000, maxSeconds: 600)
    let lower = max(0, Int(start * 8_000)), upper = min(samples.count, Int(end * 8_000))
    guard upper > lower else { return 0 }
    var sum = 0.0
    for index in lower..<upper { sum += Double(samples[index]) * Double(samples[index]) }
    return (sum / Double(upper - lower)).squareRoot()
}

func testPreset(width: Int = 360, height: Int = 640, codec: VideoCodec = .h264) -> ExportPreset {
    ExportPreset(id: "test", name: "Test", platform: "Test", width: width, height: height, frameRate: .fps30, codec: codec,
                 container: codec == .proRes422 ? .mov : .mp4, videoBitrate: 2_500_000)
}

func engine(width: Int = 1080, height: Int = 1920, background: RGBAColor = .black) -> CommandEngine {
    CommandEngine(project: Project(name: "Render test", canvas: CanvasSettings(width: width, height: height, frameRate: .fps30, background: background)))
}

func solid(_ color: RGBAColor, duration: Double, transition: Transition? = nil) -> Clip {
    Clip(kind: .solid, name: "Solid", duration: t(duration), transitionIn: transition, solidColor: color)
}

func add(_ engine: inout CommandEngine, _ clip: Clip, track: UUID? = nil) throws {
    try engine.execute(.insertClip(sequenceID: nil, trackID: track, clip: clip, index: nil))
}

func model(_ engine: CommandEngine, size: CGSize? = nil, options: RenderOptions = RenderOptions()) async throws -> RenderModel {
    try await CompositionBuilder.build(project: engine.project, resolver: pathResolver, outputSize: size, options: options).model
}

func render(_ engine: CommandEngine, at seconds: Double, size: CGSize = CGSize(width: 270, height: 480)) async throws -> Bitmap {
    let model = try await model(engine, size: size)
    return Bitmap(FrameRenderer.renderImage(model: model, at: t(seconds))!)!
}

let red = RGBAColor(r: 0.9, g: 0.1, b: 0.1), blue = RGBAColor(r: 0.1, g: 0.2, b: 0.9), green = RGBAColor(r: 0.1, g: 0.8, b: 0.2)
