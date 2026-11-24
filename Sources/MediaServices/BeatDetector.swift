import Accelerate
import Foundation
import ProjectDomain

public struct BeatAnalysis: Sendable, Equatable, Codable {
    public var bpm: Double
    /// 0…1: how strongly the audio supports this tempo.
    public var confidence: Double
    /// Beat times in seconds.
    public var beats: [Double]
    /// Indices into `beats` that are bar starts (assuming four beats to the bar).
    public var downbeats: [Int]
    /// 0…1: how clearly one beat in four stands out.
    public var downbeatConfidence: Double

    public static let none = BeatAnalysis(bpm: 0, confidence: 0, beats: [], downbeats: [], downbeatConfidence: 0)

    /// Timeline markers for the analysis, offset to where the audio sits on the timeline.
    public func markers(offset: RationalTime = .zero, sourceStart: RationalTime = .zero, limit: RationalTime? = nil,
                        seed: UUID = UUID()) -> [Marker] {
        let bars = Set(downbeats)
        var markers: [Marker] = []
        for (index, beat) in beats.enumerated() {
            let local = RationalTime(seconds: beat) - sourceStart
            guard !local.isNegative else { continue }
            if let limit, local > limit { break }
            let isBar = bars.contains(index)
            markers.append(Marker(id: UUID(deriving: seed, salt: "beat-\(index)"), time: offset + local,
                                  kind: isBar ? .downbeat : .beat,
                                  color: isBar ? RGBAColor(r: 0.98, g: 0.75, b: 0.3) : RGBAColor(r: 0.6, g: 0.62, b: 0.7)))
        }
        return markers
    }
}

/// Tempo and beat tracking: spectral-flux onset envelope → autocorrelation tempo → dynamic-programming
/// beat placement (after Ellis, "Beat Tracking by Dynamic Programming", 2007). Runs on-device.
public enum BeatDetector {
    static let sampleRate = 22_050.0
    static let frameSize = 1024
    static let hop = 256
    public static let maxAnalysisSeconds = 600.0

    public static func analyse(_ url: URL) async throws -> BeatAnalysis {
        let samples = try await AudioDecoder.decodeMono(url, sampleRate: sampleRate, maxSeconds: maxAnalysisSeconds)
        return analyse(samples: samples, sampleRate: sampleRate)
    }

    public static func analyse(samples: [Float], sampleRate: Double) -> BeatAnalysis {
        let (flux, bass) = onsetEnvelope(samples)
        guard flux.count > 32 else { return .none }
        let fps = sampleRate / Double(hop)
        let envelope = normalise(flux, fps: fps)
        guard let tempo = estimateTempo(envelope, fps: fps) else { return .none }
        let frames = trackBeats(envelope, period: tempo.period)
        guard frames.count >= 2 else { return .none }
        // A frame's flux reflects energy arriving near the centre of its analysis window.
        let latency = Double(frameSize) / 2 / sampleRate
        let beats = frames.map { Double($0) / fps + latency }
        let (downbeats, barConfidence) = findDownbeats(frames: frames, bass: bass)
        return BeatAnalysis(bpm: 60 * fps / tempo.period, confidence: tempo.confidence, beats: beats, downbeats: downbeats,
                            downbeatConfidence: barConfidence)
    }

    // MARK: Onset envelope

    static func onsetEnvelope(_ samples: [Float]) -> (flux: [Float], bass: [Float]) {
        let n = frameSize, half = n / 2
        guard samples.count >= n * 2 else { return ([], []) }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let frameCount = (samples.count - n) / hop + 1
        var flux = [Float](repeating: 0, count: frameCount)
        var bass = [Float](repeating: 0, count: frameCount)
        var previous = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        let bassBins = max(2, Int(150 / (sampleRate / Double(n))))

        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            for frame in 0..<frameCount {
                vDSP_vmul(base + frame * hop, 1, window, 1, &windowed, 1, vDSP_Length(n))
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        guard let r = realPointer.baseAddress, let i = imaginaryPointer.baseAddress else { return }
                        var split = DSPSplitComplex(realp: r, imagp: i)
                        windowed.withUnsafeBufferPointer { source in
                            source.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
                // Log compression makes quiet and loud passages contribute comparably.
                var total: Float = 0
                var low: Float = 0
                for bin in 1..<half {
                    let value = log1pf(magnitudes[bin] * 10)
                    let rise = value - previous[bin]
                    if rise > 0 {
                        total += rise
                        if bin <= bassBins { low += rise }
                    }
                    previous[bin] = value
                }
                flux[frame] = total
                bass[frame] = low
            }
        }
        if !flux.isEmpty { flux[0] = 0; bass[0] = 0 }
        return (flux, bass)
    }

    /// Removes the slowly varying level and scales to unit deviation.
    static func normalise(_ flux: [Float], fps: Double) -> [Float] {
        let radius = max(1, Int(fps * 0.4))
        var output = [Float](repeating: 0, count: flux.count)
        var running: Float = 0
        var count = 0
        var lower = 0, upper = -1
        for index in flux.indices {
            let wantUpper = min(flux.count - 1, index + radius)
            let wantLower = max(0, index - radius)
            while upper < wantUpper { upper += 1; running += flux[upper]; count += 1 }
            while lower < wantLower { running -= flux[lower]; lower += 1; count -= 1 }
            output[index] = max(0, flux[index] - running / Float(max(1, count)))
        }
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(output, 1, nil, 1, &mean, &deviation, vDSP_Length(output.count))
        guard deviation > 1e-9 else { return [Float](repeating: 0, count: flux.count) }
        var scale = 1 / deviation
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(output.count))
        return output
    }

    // MARK: Tempo

    static func estimateTempo(_ sharp: [Float], fps: Double) -> (period: Double, confidence: Double)? {
        // Onsets are only a frame or two wide, so a beat period that is not a whole number of frames
        // would correlate poorly. Widening the peaks first makes every tempo measurable.
        let kernel: [Float] = [1, 2, 3, 4, 3, 2, 1].map { $0 / 16 }
        var envelope = [Float](repeating: 0, count: sharp.count)
        if sharp.count >= kernel.count {
            let padded = [Float](repeating: 0, count: kernel.count / 2) + sharp + [Float](repeating: 0, count: kernel.count / 2)
            vDSP_conv(padded, 1, kernel, 1, &envelope, 1, vDSP_Length(sharp.count), vDSP_Length(kernel.count))
        }
        let minLag = max(2, Int(fps * 60 / 220))
        let maxLag = min(envelope.count / 2, Int(fps * 60 / 50))
        guard maxLag > minLag + 2 else { return nil }
        var energy: Float = 0
        vDSP_dotpr(envelope, 1, envelope, 1, &energy, vDSP_Length(envelope.count))
        guard energy > 1e-6 else { return nil }

        func correlation(_ lag: Int) -> Float {
            guard lag > 0, lag < envelope.count else { return 0 }
            var value: Float = 0
            envelope.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                vDSP_dotpr(base, 1, base + lag, 1, &value, vDSP_Length(envelope.count - lag))
            }
            // Unbiased: longer lags have fewer terms.
            return value / Float(envelope.count - lag) * Float(envelope.count)
        }

        var scores = [Double](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            // Mild preference for moderate tempi (log-normal around 120 BPM, one octave wide). This is what
            // settles the half/double-tempo ambiguity that any periodic signal has.
            let combined = Double(correlation(lag))
            let bpm = 60 * fps / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120), 2))
            scores[lag] = combined * prior
        }
        guard let best = (minLag...maxLag).max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        // Parabolic refinement for sub-frame precision.
        var period = Double(best)
        if best > minLag, best < maxLag {
            let a = scores[best - 1], b = scores[best], c = scores[best + 1]
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 { period += 0.5 * (a - c) / denominator }
        }
        let confidence = max(0, min(1, Double(correlation(best)) / Double(energy)))
        return (period, confidence)
    }

    // MARK: Beat tracking

    static func trackBeats(_ envelope: [Float], period: Double, tightness: Double = 100) -> [Int] {
        let count = envelope.count
        guard count > 2, period >= 2 else { return [] }
        var score = [Double](repeating: 0, count: count)
        var link = [Int](repeating: -1, count: count)
        let nearest = max(1, Int((period / 2).rounded()))
        let farthest = max(nearest + 1, Int((period * 2).rounded()))
        for t in 0..<count {
            var best = -Double.infinity
            var bestIndex = -1
            let lower = t - farthest, upper = t - nearest
            if upper >= 0 {
                for previous in max(0, lower)...upper {
                    let ratio = Double(t - previous) / period
                    let penalty = -tightness * pow(log(ratio), 2)
                    let candidate = score[previous] + penalty
                    if candidate > best { best = candidate; bestIndex = previous }
                }
            }
            let local = Double(envelope[t])
            if bestIndex >= 0, best > 0 {
                score[t] = local + best
                link[t] = bestIndex
            } else {
                score[t] = local
            }
        }
        // Start the backtrace from the strongest candidate in the final beat period.
        let tailStart = max(0, count - Int(period.rounded()) - 1)
        guard var cursor = (tailStart..<count).max(by: { score[$0] < score[$1] }) else { return [] }
        var beats: [Int] = []
        while cursor >= 0 {
            beats.append(cursor)
            cursor = link[cursor]
        }
        return beats.reversed()
    }

    // MARK: Downbeats

    static func findDownbeats(frames: [Int], bass: [Float]) -> (indices: [Int], confidence: Double) {
        guard frames.count >= 8 else { return ([], 0) }
        var sums = [Double](repeating: 0, count: 4)
        var counts = [Int](repeating: 0, count: 4)
        for (index, frame) in frames.enumerated() where frame < bass.count {
            // Peak bass onset within a few frames of the beat.
            var value: Float = 0
            for offset in -2...2 where frame + offset >= 0 && frame + offset < bass.count {
                value = max(value, bass[frame + offset])
            }
            sums[index % 4] += Double(value)
            counts[index % 4] += 1
        }
        let averages = (0..<4).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
        guard let phase = averages.indices.max(by: { averages[$0] < averages[$1] }), averages[phase] > 0 else { return ([], 0) }
        let others = averages.enumerated().filter { $0.offset != phase }.map(\.element)
        let rest = others.reduce(0, +) / Double(others.count)
        let confidence = max(0, min(1, (averages[phase] - rest) / averages[phase]))
        return (Array(stride(from: phase, to: frames.count, by: 4)), confidence)
    }
}
