import AVFoundation
import CoreImage
import Foundation
import MediaServices
import ProjectDomain

/// Carries the render model to the compositor. One instruction spans the whole timeline; the model
/// decides what is on screen at each time.
final class KirieInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let model: RenderModel

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], model: RenderModel) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.model = model
    }
}

/// AVFoundation custom compositor: receives decoded source frames and renders each output frame on
/// the GPU through `FrameRenderer`. The same class serves AVPlayer preview and export.
final class KirieCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "kirie.compositor", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    static let bufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    var sourcePixelBufferAttributes: [String: Any]? { KirieCompositor.bufferAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { KirieCompositor.bufferAttributes }
    var supportsWideColorSourceFrames: Bool { false }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        cancelled = false
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let stop = cancelled
            lock.unlock()
            if stop {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? KirieInstruction else {
                request.finish(with: RenderError.internalFailure("Unexpected composition instruction."))
                return
            }
            guard let buffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: RenderError.internalFailure("No output buffer was available."))
                return
            }
            let model = instruction.model
            let image = FrameRenderer.render(model: model, at: RationalTime(request.compositionTime)) { trackID in
                request.sourceFrame(byTrackID: trackID).map { CIImage(cvPixelBuffer: $0) }
            }
            // The render context may be smaller than the model (reduced-quality preview).
            let target = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            var final = image
            if abs(target.width - model.outputSize.width) > 0.5 || abs(target.height - model.outputSize.height) > 0.5 {
                final = image.transformed(by: CGAffineTransform(scaleX: target.width / model.outputSize.width, y: target.height / model.outputSize.height))
            }
            FrameRenderer.context.render(final, to: buffer, bounds: CGRect(origin: .zero, size: target), colorSpace: FrameRenderer.outputColorSpace)
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.async(flags: .barrier) { [self] in
            lock.lock()
            cancelled = false
            lock.unlock()
        }
    }
}

public enum RenderError: Error, Equatable, LocalizedError {
    case emptyTimeline
    case missingMedia([String])
    case invalidPreset([String])
    case exportLocked([String])
    case encoderUnavailable(String)
    case cancelled
    case failed(String)
    case internalFailure(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline is empty. Add a clip before exporting."
        case .missingMedia(let names): "Missing media: \(names.joined(separator: ", ")). Relink or remove these clips, then try again."
        case .invalidPreset(let problems): "These export settings cannot be used: " + problems.joined(separator: " ")
        case .exportLocked(let reasons): "Export is locked until QA passes. " + reasons.joined(separator: " ")
        case .encoderUnavailable(let codec): "\(codec) encoding is not available on this Mac. Choose another codec."
        case .cancelled: "The export was cancelled."
        case .failed(let detail): "The export failed. \(detail)"
        case .internalFailure(let detail): "Rendering failed. \(detail)"
        }
    }
}

/// A tiny black clip that gives every composition a video track spanning its full length, so
/// timelines made only of stills, text and solids still render frame by frame.
actor BaseClip {
    static let shared = BaseClip()
    static let seconds = 4.0
    private var pending: Task<URL, Error>?

    func url() async throws -> URL {
        if let pending { return try await pending.value }
        let task = Task<URL, Error> {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirie-render", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("base-v3.mov")
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 512 { return url }
            // Write beside the final name, then rename, so another process never sees a partial file.
            let temporary = directory.appendingPathComponent("base-\(UUID().uuidString).mov")
            try await BaseClip.write(to: temporary)
            if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.fileExists(atPath: url.path) else { throw RenderError.internalFailure("The base clip could not be created.") }
            return url
        }
        pending = task
        do {
            return try await task.value
        } catch {
            pending = nil
            throw error
        }
    }

    private static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000, AVVideoMaxKeyFrameIntervalKey: 1],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw RenderError.internalFailure(writer.error?.localizedDescription ?? "The base clip could not be created.") }
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        let total = Int(seconds * Double(fps))
        for frame in 0..<total {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                waited += 1
                if waited > 5_000 { throw RenderError.internalFailure("The base clip encoder stalled.") }
            }
            var buffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
            guard let buffer else { throw RenderError.internalFailure("The base clip could not be created.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw RenderError.internalFailure(writer.error?.localizedDescription ?? "The base clip could not be created.")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw RenderError.internalFailure(writer.error?.localizedDescription ?? "The base clip could not be created.") }
    }
}
