import AVFoundation
import Accelerate
import Foundation
import ProjectDomain

/// Runs blocking media work on a GCD thread.
///
/// AVFoundation's synchronous calls (`copyNextSampleBuffer` and friends) wait for work that
/// AVFoundation itself schedules on Swift's cooperative thread pool. If they are called from async
/// code they occupy pool threads, and enough of them at once (more than the Mac has cores, or even a
/// handful on a small machine) leave no thread free to produce the data they are waiting for: a
/// deadlock. Blocking calls therefore always go through here.
public enum BlockingWork {
    private static let queue = DispatchQueue(label: "kirie.blocking-media", qos: .userInitiated, attributes: .concurrent)

    public static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// A flag another thread can set to ask blocking work to stop.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Decodes any audio (or the audio of a video) to mono Float32 PCM.
public enum AudioDecoder {
    /// Streams decoded samples to `consume` in chunks, off the cooperative pool. `consume` is called
    /// on a background thread, one chunk at a time, and has returned for the last time before this
    /// function returns. Returns the number of samples delivered.
    @discardableResult
    public static func stream(_ url: URL, sampleRate: Double, maxSeconds: Double = .infinity,
                              consume: @escaping (UnsafeBufferPointer<Float>) -> Void) async throws -> Int {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MediaError.decodeFailed(name, detail: error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw MediaError.empty(name) }
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await BlockingWork.run {
                let reader: AVAssetReader
                do {
                    reader = try AVAssetReader(asset: asset)
                } catch {
                    throw MediaError.decodeFailed(name, detail: error.localizedDescription)
                }
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: sampleRate,
                ]
                let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw MediaError.decodeFailed(name, detail: "The audio format cannot be converted.") }
                reader.add(output)
                guard reader.startReading() else {
                    throw MediaError.decodeFailed(name, detail: reader.error?.localizedDescription ?? "Reading could not start.")
                }
                let limit = maxSeconds.isFinite ? Int(maxSeconds * sampleRate) : Int.max
                var delivered = 0
                while delivered < limit, let buffer = output.copyNextSampleBuffer() {
                    if flag.isCancelled {
                        reader.cancelReading()
                        throw CancellationError()
                    }
                    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                    var length = 0
                    var pointer: UnsafeMutablePointer<Int8>?
                    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                          let pointer else { continue }
                    let count = min(length / MemoryLayout<Float>.size, limit - delivered)
                    pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                        consume(UnsafeBufferPointer(start: floats, count: count))
                    }
                    delivered += count
                }
                if reader.status == .failed {
                    throw MediaError.decodeFailed(name, detail: reader.error?.localizedDescription ?? "Decoding stopped early.")
                }
                reader.cancelReading()
                return delivered
            }
        } onCancel: {
            flag.cancel()
        }
    }

    public static func decodeMono(_ url: URL, sampleRate: Double, maxSeconds: Double) async throws -> [Float] {
        let box = SampleBox()
        try await stream(url, sampleRate: sampleRate, maxSeconds: maxSeconds) { box.samples.append(contentsOf: $0) }
        return box.samples
    }

    /// Holds samples while they are gathered on the decoding thread.
    private final class SampleBox: @unchecked Sendable { var samples: [Float] = [] }
}

/// Peak envelope for drawing waveforms.
public struct Waveform: Sendable, Equatable {
    public var peaksPerSecond: Double
    /// Peak magnitude per bucket, 0…1.
    public var peaks: [Float]

    public init(peaksPerSecond: Double, peaks: [Float]) {
        self.peaksPerSecond = peaksPerSecond
        self.peaks = peaks
    }

    public var duration: Double { Double(peaks.count) / peaksPerSecond }

    /// Largest peak in a time span, for drawing one pixel column.
    public func peak(from start: Double, to end: Double) -> Float {
        guard !peaks.isEmpty else { return 0 }
        let lower = max(0, min(peaks.count - 1, Int(start * peaksPerSecond)))
        let upper = max(lower, min(peaks.count - 1, Int(end * peaksPerSecond)))
        var value: Float = 0
        for index in lower...upper { value = max(value, peaks[index]) }
        return value
    }

    private static let magic: [UInt8] = Array("KWF1".utf8)

    public var data: Data {
        var data = Data(Waveform.magic)
        withUnsafeBytes(of: peaksPerSecond.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(peaks.count).littleEndian) { data.append(contentsOf: $0) }
        peaks.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    public init?(data: Data) {
        guard data.count >= 16, Array(data.prefix(4)) == Waveform.magic else { return nil }
        let rate = data.subdata(in: 4..<12).withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        let count = Int(data.subdata(in: 12..<16).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard rate.isFinite, rate > 0, count >= 0, data.count == 16 + count * MemoryLayout<Float>.size else { return nil }
        var peaks = [Float](repeating: 0, count: count)
        _ = peaks.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 16..<data.count) }
        self.init(peaksPerSecond: rate, peaks: peaks)
    }
}

public enum WaveformGenerator {
    private final class Accumulator: @unchecked Sendable {
        var peaks: [Float] = []
        var current: Float = 0
        var filled = 0
    }

    public static func generate(_ url: URL, peaksPerSecond: Double = 100) async throws -> Waveform {
        let sampleRate = 8_000.0
        let bucket = max(1, Int(sampleRate / peaksPerSecond))
        let state = Accumulator()
        try await AudioDecoder.stream(url, sampleRate: sampleRate) { samples in
            var offset = 0
            while offset < samples.count {
                let take = min(bucket - state.filled, samples.count - offset)
                var peak: Float = 0
                if let base = samples.baseAddress { vDSP_maxmgv(base + offset, 1, &peak, vDSP_Length(take)) }
                state.current = max(state.current, peak)
                state.filled += take
                offset += take
                if state.filled == bucket {
                    state.peaks.append(min(1, state.current))
                    state.current = 0
                    state.filled = 0
                }
            }
        }
        if state.filled > 0 { state.peaks.append(min(1, state.current)) }
        return Waveform(peaksPerSecond: sampleRate / Double(bucket), peaks: state.peaks)
    }
}
