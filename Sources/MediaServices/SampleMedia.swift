import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ProjectDomain

/// Generates small, licence-free media: test fixtures and the demo project are built from these
/// rather than from bundled files.
public enum SampleMedia {
    // MARK: Audio

    /// A click track: a tick on every beat with an accented, bass-heavy first beat of each bar.
    public static func writeClickTrack(to url: URL, bpm: Double, seconds: Double, sampleRate: Int = 44_100, firstBeat: Double = 0.25) throws {
        let count = Int(seconds * Double(sampleRate))
        var samples = [Float](repeating: 0, count: count)
        let interval = 60 / bpm
        var beat = 0
        while firstBeat + Double(beat) * interval < seconds {
            let start = Int((firstBeat + Double(beat) * interval) * Double(sampleRate))
            let accented = beat % 4 == 0
            let length = Int(0.09 * Double(sampleRate))
            for i in 0..<length where start + i < count {
                let t = Double(i) / Double(sampleRate)
                let envelope = exp(-t * 45)
                var value = sin(2 * .pi * 1_400 * t) * envelope * (accented ? 0.55 : 0.4)
                if accented { value += sin(2 * .pi * 70 * t) * exp(-t * 22) * 0.6 }
                samples[start + i] += Float(value)
            }
            beat += 1
        }
        try writeWAV(samples, to: url, sampleRate: sampleRate)
    }

    public static func writeTone(to url: URL, frequency: Double, seconds: Double, sampleRate: Int = 44_100, amplitude: Double = 0.3) throws {
        let count = Int(seconds * Double(sampleRate))
        let samples = (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / Double(sampleRate)) * amplitude) }
        try writeWAV(samples, to: url, sampleRate: sampleRate)
    }

    /// 16-bit mono PCM WAV.
    public static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Int) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        data.reserveCapacity(44 + byteCount)
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32_767)) }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Drawing

    public static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    /// Draws centred text. Coordinates are CoreGraphics (origin bottom-left).
    public static func drawText(_ text: String, in context: CGContext, center: CGPoint, size: CGFloat, color: RGBAColor, font: String = "Helvetica-Bold") {
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    }

    /// A flat-colour still with a label and a simple figure, for montage and lyric tests.
    public static func writeStill(to url: URL, width: Int = 1024, height: Int = 1536, color: RGBAColor, label: String) throws {
        guard let context = makeContext(width: width, height: height) else { throw MediaError.decodeFailed(url.lastPathComponent, detail: "Could not create a drawing surface.") }
        context.setFillColor(cgColor(color))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The "character" sits in the lower 60%, leaving the top clear for lettering.
        let radius = CGFloat(width) * 0.16
        context.setFillColor(cgColor(RGBAColor(r: 0.2, g: 0.2, b: 0.25)))
        context.fillEllipse(in: CGRect(x: CGFloat(width) / 2 - radius, y: CGFloat(height) * 0.30, width: radius * 2, height: radius * 2))
        context.fill(CGRect(x: CGFloat(width) / 2 - radius * 0.8, y: CGFloat(height) * 0.08, width: radius * 1.6, height: CGFloat(height) * 0.24))
        drawText(label, in: context, center: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) * 0.05), size: CGFloat(width) * 0.05,
                 color: RGBAColor(r: 0.2, g: 0.2, b: 0.25))
        guard let image = context.makeImage(), Thumbnailer.write(image, to: url) else {
            throw MediaError.decodeFailed(url.lastPathComponent, detail: "Could not write the image.")
        }
    }

    /// A comic strip with unequal panels on a paper-coloured page. Returns the true panel rectangles
    /// (normalised, top-left origin, reading order) so detection can be checked against them.
    @discardableResult
    public static func writeComicStrip(to url: URL, width: Int = 1024, height: Int = 1536,
                                       layout: [UnitRect]? = nil, paper: RGBAColor = .paper) throws -> [UnitRect] {
        let panels = layout ?? [
            UnitRect(x: 0.04, y: 0.03, width: 0.92, height: 0.27),
            UnitRect(x: 0.04, y: 0.33, width: 0.40, height: 0.30),
            UnitRect(x: 0.48, y: 0.33, width: 0.48, height: 0.30),
            UnitRect(x: 0.04, y: 0.66, width: 0.92, height: 0.31),
        ]
        guard let context = makeContext(width: width, height: height) else { throw MediaError.decodeFailed(url.lastPathComponent, detail: "Could not create a drawing surface.") }
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(cgColor(paper))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let tints = [RGBAColor(r: 0.72, g: 0.83, b: 0.93), RGBAColor(r: 0.96, g: 0.80, b: 0.74), RGBAColor(r: 0.80, g: 0.90, b: 0.76),
                     RGBAColor(r: 0.93, g: 0.86, b: 0.66), RGBAColor(r: 0.85, g: 0.79, b: 0.93)]
        let ink = RGBAColor(r: 0.13, g: 0.11, b: 0.1)
        for (index, panel) in panels.enumerated() {
            // Flip to CoreGraphics coordinates.
            let rect = CGRect(x: panel.x * w, y: (1 - panel.maxY) * h, width: panel.width * w, height: panel.height * h)
            context.setFillColor(cgColor(tints[index % tints.count]))
            context.fill(rect)
            context.setStrokeColor(cgColor(ink))
            context.setLineWidth(max(3, w * 0.005))
            context.stroke(rect.insetBy(dx: w * 0.0025, dy: w * 0.0025))
            // A chibi-ish figure: head and body, placed off-centre so framing has something to find.
            let head = min(rect.width, rect.height) * 0.2
            let cx = rect.minX + rect.width * (index % 2 == 0 ? 0.35 : 0.62)
            let cy = rect.minY + rect.height * 0.5
            context.setFillColor(cgColor(ink))
            context.fillEllipse(in: CGRect(x: cx - head, y: cy - head * 0.2, width: head * 2, height: head * 2))
            context.fill(CGRect(x: cx - head * 0.6, y: cy - head * 1.6, width: head * 1.2, height: head * 1.5))
            drawText("\(index + 1)", in: context, center: CGPoint(x: rect.maxX - head * 0.7, y: rect.maxY - head * 0.7), size: head * 0.8, color: ink)
        }
        guard let image = context.makeImage(), Thumbnailer.write(image, to: url) else {
            throw MediaError.decodeFailed(url.lastPathComponent, detail: "Could not write the image.")
        }
        return panels
    }

    // MARK: Video

    /// A test clip: flat colour, a bar that sweeps left to right once per second, and a burned-in
    /// frame counter. Optionally muxes a sine tone so the clip has sound.
    public static func writeTestVideo(to url: URL, width: Int = 640, height: Int = 360, fps: Int32 = 30, seconds: Double = 3,
                                      color: RGBAColor, label: String, toneFrequency: Double? = nil) async throws {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        let videoURL = toneFrequency == nil ? url : url.deletingLastPathComponent().appendingPathComponent("picture-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000, AVVideoMaxKeyFrameIntervalKey: Int(fps)],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaError.decodeFailed(url.lastPathComponent, detail: "The encoder could not start.") }
        writer.startSession(atSourceTime: .zero)
        let total = Int((seconds * Double(fps)).rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        for frame in 0..<total {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                // A failed or stalled encoder must surface as an error, never as an endless wait.
                guard writer.status == .writing, waited < 15_000 else {
                    writer.cancelWriting()
                    throw writer.error ?? MediaError.decodeFailed(url.lastPathComponent, detail: "The video encoder stopped accepting frames.")
                }
                try await Task.sleep(nanoseconds: 2_000_000)
                waited += 1
            }
            guard let pool = adaptor.pixelBufferPool else { throw MediaError.decodeFailed(url.lastPathComponent, detail: "No pixel buffer pool.") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw MediaError.decodeFailed(url.lastPathComponent, detail: "No pixel buffer.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.setFillColor(cgColor(color))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let phase = Double(frame % Int(fps)) / Double(fps)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
                context.fill(CGRect(x: phase * Double(width - 20), y: 0, width: 20, height: Double(height) * 0.12))
                drawText(label, in: context, center: CGPoint(x: Double(width) / 2, y: Double(height) * 0.6), size: Double(height) * 0.16, color: .white)
                drawText(String(format: "%04d", frame), in: context, center: CGPoint(x: Double(width) / 2, y: Double(height) * 0.36),
                         size: Double(height) * 0.12, color: .white, font: "Menlo-Bold")
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaError.decodeFailed(url.lastPathComponent, detail: "The encoder failed.") }
        guard let toneFrequency else { return }

        // Mux the picture with a tone.
        let toneURL = url.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).wav")
        defer { try? manager.removeItem(at: toneURL); try? manager.removeItem(at: videoURL) }
        try writeTone(to: toneURL, frequency: toneFrequency, seconds: seconds)
        let composition = AVMutableComposition()
        let picture = AVURLAsset(url: videoURL), sound = AVURLAsset(url: toneURL)
        let duration = try await picture.load(.duration)
        if let source = try await picture.loadTracks(withMediaType: .video).first,
           let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        if let source = try await sound.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError.decodeFailed(url.lastPathComponent, detail: "Could not mux audio.")
        }
        export.outputURL = url
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else { throw export.error ?? MediaError.decodeFailed(url.lastPathComponent, detail: "Muxing failed.") }
    }
}
