import AVFoundation
import CoreImage
import Foundation
import MediaServices
import ProjectDomain
import VideoToolbox

public struct VerificationCheck: Sendable, Equatable, Codable {
    public var name: String
    public var passed: Bool
    public var expected: String
    public var actual: String
}

/// Result of probing an exported file independently of the encoder that wrote it.
public struct VerificationReport: Sendable, Equatable, Codable {
    public var checks: [VerificationCheck]
    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failures: [VerificationCheck] { checks.filter { !$0.passed } }
}

public struct ExportReport: Sendable, Equatable, Codable {
    public var outputPath: String
    public var presetID: String
    public var durationSeconds: Double
    public var fileSize: Int64
    public var framesWritten: Int
    public var elapsedSeconds: Double
    public var hasAudio: Bool
    /// Audio left out because it is commercial music without export rights.
    public var withheldAudio: [String]
    /// Path of the song note written alongside a silent export, if any.
    public var songNotePath: String?
    public var verification: VerificationReport
}

/// What the caller wants exported.
public struct ExportRequest: Sendable {
    public var preset: ExportPreset
    public var destination: URL
    public var range: TimeRange?
    public var options: RenderOptions
    public var songNote: SongNote?

    public init(preset: ExportPreset, destination: URL, range: TimeRange? = nil, options: RenderOptions = RenderOptions(),
                songNote: SongNote? = nil) {
        self.preset = preset
        self.destination = destination
        self.range = range
        self.options = options
        self.songNote = songNote
    }
}

/// Cooperative cancellation shared between the UI and the export pipeline.
public final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Real export: AVAssetReader pulls composed frames (through the GPU compositor) and mixed audio,
/// AVAssetWriter encodes them with VideoToolbox hardware encoders where available. The output is
/// written to a temporary file, verified by probing, and only then moved into place.
public enum Exporter {
    static func fourCC(for codec: VideoCodec) -> String {
        switch codec {
        case .h264: "avc1"
        case .hevc: "hvc1"
        case .proRes422: "apcn"
        }
    }

    static func videoSettings(for preset: ExportPreset) -> [String: Any] {
        var settings: [String: Any] = [AVVideoWidthKey: preset.width, AVVideoHeightKey: preset.height]
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        settings[AVVideoColorPropertiesKey] = color
        let fps = preset.frameRate.fps
        switch preset.codec {
        case .h264:
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: preset.videoBitrate, AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()), AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any]
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: preset.videoBitrate, AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
            ] as [String: Any]
        case .proRes422:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        }
        return settings
    }

    public static func encoderAvailable(_ codec: VideoCodec) -> Bool {
        let type: CMVideoCodecType = switch codec {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .proRes422: kCMVideoCodecType_AppleProRes422
        }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: type, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }

    /// Exports a sequence. `progress` receives 0…1 on an arbitrary queue.
    public static func export(project: Project, sequenceID: UUID? = nil, resolver: MediaResolving, request: ExportRequest,
                              cancellation: ExportCancellation = ExportCancellation(),
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExportReport {
        let preset = request.preset
        let problems = preset.validationProblems()
        guard problems.isEmpty else { throw RenderError.invalidPreset(problems) }
        guard encoderAvailable(preset.codec) else { throw RenderError.encoderUnavailable(preset.codec.displayName) }
        var options = request.options
        options.reduceMotion = options.reduceMotion || preset.reduceMotion
        let built = try await CompositionBuilder.build(project: project, sequenceID: sequenceID, resolver: resolver,
                                                       outputSize: CGSize(width: preset.width, height: preset.height),
                                                       frameRate: preset.frameRate, options: options)
        guard built.missingMedia.isEmpty else { throw RenderError.missingMedia(built.missingMedia) }

        let full = CMTimeRange(start: .zero, duration: built.duration)
        var range = full
        if let wanted = request.range {
            range = wanted.cmTimeRange.intersection(full)
            guard range.duration > .zero else { throw RenderError.failed("The export range is outside the timeline.") }
        }
        let manager = FileManager.default
        let destination = request.destination
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Hidden, uniquely named, and with the real extension so it can be probed before publishing.
        let stem = ".\(destination.deletingPathExtension().lastPathComponent).\(UUID().uuidString.prefix(8)).partial"
        let partial = destination.deletingLastPathComponent().appendingPathComponent("\(stem).\(preset.container.fileExtension)")
        /// Removes the partial file and anything the encoder left beside it.
        func discardPartial() {
            let directory = partial.deletingLastPathComponent()
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(stem) {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        discardPartial()
        let started = Date()

        let counter = FrameCounter()
        // A range with no sound in it gets no audio track rather than an empty one.
        let includeAudio = built.hasAudio(in: range)
        do {
            try await run(built: built, preset: preset, range: range, includeAudio: includeAudio, to: partial, cancellation: cancellation,
                          counter: counter, progress: progress)
        } catch {
            // A failed or cancelled export never leaves a file that looks finished.
            discardPartial()
            throw error
        }

        // Verify before publishing the file.
        let expected = ExpectedOutput(duration: range.duration.seconds, width: preset.width, height: preset.height,
                                      frameRate: preset.frameRate.fps, codec: fourCC(for: preset.codec), hasAudio: includeAudio)
        let verification = await verify(partial, expected: expected)
        guard verification.passed else {
            discardPartial()
            let detail = verification.failures.map { "\($0.name): expected \($0.expected), got \($0.actual)" }.joined(separator: "; ")
            throw RenderError.failed("The exported file did not pass verification (\(detail)).")
        }
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: partial, to: destination)
        } catch {
            discardPartial()
            throw RenderError.failed("The finished file could not be moved into place: \(error.localizedDescription)")
        }

        var notePath: String?
        if !built.withheldAudio.isEmpty || (options.silent && !(request.songNote?.isEmpty ?? true)) {
            notePath = writeSongNote(for: destination, withheld: built.withheldAudio, note: request.songNote)
        }
        let size = ((try? manager.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        progress(1)
        return ExportReport(outputPath: destination.path, presetID: preset.id, durationSeconds: range.duration.seconds, fileSize: size,
                            framesWritten: counter.value, elapsedSeconds: Date().timeIntervalSince(started), hasAudio: includeAudio,
                            withheldAudio: built.withheldAudio.map(\.name), songNotePath: notePath, verification: verification)
    }

    final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private static func run(built: BuiltComposition, preset: ExportPreset, range: CMTimeRange, includeAudio: Bool, to url: URL,
                            cancellation: ExportCancellation, counter: FrameCounter,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: built.composition)
            writer = try AVAssetWriter(outputURL: url, fileType: preset.container == .mp4 ? .mp4 : .mov)
        } catch {
            throw RenderError.failed(error.localizedDescription)
        }
        reader.timeRange = range
        writer.shouldOptimizeForNetworkUse = true

        let videoTracks = built.composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw RenderError.failed("The timeline could not be prepared for rendering.") }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(for: preset))
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw RenderError.encoderUnavailable(preset.codec.displayName) }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        let audioTracks = built.composition.tracks(withMediaType: .audio)
        if includeAudio, !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: preset.audio.sampleRate, AVNumberOfChannelsKey: preset.audio.channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = preset.audio.channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: preset.audio.sampleRate, AVNumberOfChannelsKey: preset.audio.channels,
                    AVEncoderBitRateKey: preset.audio.bitrate,
                    AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                ])
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioOutput = output
                    audioInput = input
                }
            }
        }

        guard reader.startReading() else { throw RenderError.failed(reader.error?.localizedDescription ?? "Reading the timeline could not start.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RenderError.failed(writer.error?.localizedDescription ?? "The encoder could not start.")
        }
        writer.startSession(atSourceTime: range.start)

        let total = max(range.duration.seconds, 0.001)
        let failure = FailureBox()

        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, isVideo: Bool) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let queue = DispatchQueue(label: "kirie.export.\(label)")
                let state = PumpState()
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if state.finished { return }
                        if cancellation.isCancelled || failure.hasError {
                            state.finished = true
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            state.finished = true
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        if !input.append(sample) {
                            failure.set(writer.error?.localizedDescription ?? "A \(label) sample could not be written.")
                            state.finished = true
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        if isVideo {
                            counter.increment()
                            let time = CMSampleBufferGetPresentationTimeStamp(sample)
                            progress(min(0.99, max(0, (time - range.start).seconds / total)))
                        }
                    }
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(videoInput, videoOutput, label: "video", isVideo: true) }
            if let audioInput, let audioOutput {
                group.addTask { await pump(audioInput, audioOutput, label: "audio", isVideo: false) }
            }
        }

        if cancellation.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw RenderError.cancelled
        }
        if let message = failure.message {
            reader.cancelReading()
            writer.cancelWriting()
            throw RenderError.failed(message)
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw RenderError.failed(reader.error?.localizedDescription ?? "Rendering stopped early.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.failed(writer.error?.localizedDescription ?? "The file could not be finished.")
        }
    }

    final class PumpState: @unchecked Sendable { var finished = false }

    final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ message: String) { lock.lock(); if stored == nil { stored = message }; lock.unlock() }
        var message: String? { lock.lock(); defer { lock.unlock() }; return stored }
        var hasError: Bool { message != nil }
    }

    // MARK: Verification

    public struct ExpectedOutput: Sendable {
        public var duration: Double
        public var width: Int
        public var height: Int
        public var frameRate: Double
        public var codec: String
        public var hasAudio: Bool

        public init(duration: Double, width: Int, height: Int, frameRate: Double, codec: String, hasAudio: Bool) {
            self.duration = duration
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.codec = codec
            self.hasAudio = hasAudio
        }
    }

    /// Re-opens the file from disk and checks it is what was asked for.
    public static func verify(_ url: URL, expected: ExpectedOutput) async -> VerificationReport {
        var checks: [VerificationCheck] = []
        guard let (kind, metadata) = try? await MediaProbe.probe(url) else {
            return VerificationReport(checks: [VerificationCheck(name: "readable", passed: false, expected: "a playable file", actual: "unreadable")])
        }
        checks.append(VerificationCheck(name: "readable", passed: kind == .video, expected: "video", actual: kind.rawValue))
        // One frame of slack, plus AAC priming when there is sound.
        let tolerance = 1.5 / max(1, expected.frameRate) + (expected.hasAudio ? 0.08 : 0)
        checks.append(VerificationCheck(name: "duration", passed: abs(metadata.duration.seconds - expected.duration) <= tolerance,
                                        expected: String(format: "%.3f s", expected.duration), actual: String(format: "%.3f s", metadata.duration.seconds)))
        checks.append(VerificationCheck(name: "dimensions", passed: metadata.width == expected.width && metadata.height == expected.height,
                                        expected: "\(expected.width)×\(expected.height)", actual: "\(metadata.width)×\(metadata.height)"))
        checks.append(VerificationCheck(name: "frame rate", passed: abs(metadata.frameRate - expected.frameRate) <= 0.5,
                                        expected: String(format: "%.2f fps", expected.frameRate), actual: String(format: "%.2f fps", metadata.frameRate)))
        checks.append(VerificationCheck(name: "codec", passed: metadata.videoCodec == expected.codec, expected: expected.codec,
                                        actual: metadata.videoCodec ?? "none"))
        checks.append(VerificationCheck(name: "audio", passed: metadata.hasAudio == expected.hasAudio,
                                        expected: expected.hasAudio ? "present" : "absent", actual: metadata.hasAudio ? "present" : "absent"))
        return VerificationReport(checks: checks)
    }

    // MARK: Song note

    /// Writes a plain-text note next to a silent export saying which song to add on the platform.
    static func writeSongNote(for destination: URL, withheld: [MediaAsset], note: SongNote?) -> String? {
        var lines = ["This video was exported without its music.", ""]
        if let note, !note.isEmpty {
            lines.append("Add this song in the app when you post:")
            if !note.title.isEmpty { lines.append("  Song: \(note.title)") }
            if !note.artist.isEmpty { lines.append("  Artist: \(note.artist)") }
            if !note.section.isEmpty { lines.append("  Section: \(note.section)") }
            lines.append("")
        }
        if !withheld.isEmpty {
            lines.append("Audio left out because it is marked as commercial music without export rights:")
            for asset in withheld {
                let title = asset.rights.title ?? asset.name
                let artist = asset.rights.artist.map { " – \($0)" } ?? ""
                lines.append("  • \(title)\(artist)")
            }
            lines.append("")
            lines.append("The cuts were timed to this audio, so line the song up from its start.")
        }
        let url = destination.deletingPathExtension().appendingPathExtension("song-note.txt")
        do {
            try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: Stills and audio

    /// Renders one frame of the timeline, decoding video as needed.
    public static func still(built: BuiltComposition, at time: RationalTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try await generator.image(at: time.cmTime).image
        } catch {
            throw RenderError.failed(error.localizedDescription)
        }
    }

    /// Exports the mixed audio of a timeline as a 16-bit WAV.
    public static func exportAudio(built: BuiltComposition, to destination: URL, sampleRate: Double = 48_000) async throws {
        let tracks = built.composition.tracks(withMediaType: .audio)
        guard built.hasAudio, !tracks.isEmpty else { throw RenderError.failed("The timeline has no audio to export.") }
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)
        let reader = try AVAssetReader(asset: built.composition)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = built.audioMix
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: partial, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw RenderError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Audio export could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        while let sample = output.copyNextSampleBuffer() {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, waited < 30_000 else {
                    reader.cancelReading()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: partial)
                    throw RenderError.failed(writer.error?.localizedDescription ?? "The audio encoder stopped accepting data.")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
                waited += 1
            }
            guard input.append(sample) else { break }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, reader.status != .failed else {
            try? FileManager.default.removeItem(at: partial)
            throw RenderError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Audio export failed.")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
