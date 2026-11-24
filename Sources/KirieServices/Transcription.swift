import AVFoundation
import Foundation
import MediaServices
import ProjectDomain
import Speech

public enum TranscriptionError: Error, Equatable, LocalizedError {
    case notAuthorised
    case unavailable(String)
    case onDeviceUnsupported(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorised: "Kirie needs permission to use Speech Recognition. Allow it in System Settings › Privacy & Security › Speech Recognition, then try again."
        case .unavailable(let locale): "Speech recognition is not available for \(locale) right now."
        case .onDeviceUnsupported(let locale): "On-device transcription is not installed for \(locale). Kirie never sends audio to a server, so add the language in System Settings › Keyboard › Dictation."
        case .failed(let detail): "Transcription failed. \(detail)"
        }
    }
}

/// On-device captioning with Apple's Speech framework. Audio never leaves the Mac: recognition is
/// forced on-device and the request fails rather than fall back to a server.
///
/// Speech recognition needs a user permission prompt, which only an app bundle with a usage
/// description can show, so this path is exercised in the app, not in the automated tests.
public enum SpeechTranscriber {
    public static func authorise() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
    }

    /// Transcribes a media file into caption segments with word timing.
    public static func transcribe(_ url: URL, locale: Locale = .current, maxWordsPerCaption: Int = 7, maxSecondsPerCaption: Double = 3.2) async throws -> [CaptionSegment] {
        guard await authorise() else { throw TranscriptionError.notAuthorised }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.unavailable(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnsupported(locale.identifier) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let words: [TimedWord] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                } else if let result, result.isFinal {
                    finished = true
                    let timed = result.bestTranscription.segments.map {
                        TimedWord(text: $0.substring, start: RationalTime(seconds: $0.timestamp, timescale: 1000),
                                  end: RationalTime(seconds: $0.timestamp + max($0.duration, 0.05), timescale: 1000))
                    }
                    continuation.resume(returning: timed)
                }
            }
        }
        return group(words, maxWords: maxWordsPerCaption, maxSeconds: maxSecondsPerCaption)
    }

    /// Groups recognised words into readable captions: a new caption after a pause, a sentence end,
    /// or when the caption gets too long.
    public static func group(_ words: [TimedWord], maxWords: Int = 7, maxSeconds: Double = 3.2, pause: Double = 0.6) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        var current: [TimedWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(CaptionSegment(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " "), words: current))
            current = []
        }
        for word in words {
            if let last = current.last, let first = current.first {
                let gap = (word.start - last.end).seconds
                let length = (word.end - first.start).seconds
                let sentenceEnd = last.text.last.map { ".!?".contains($0) } ?? false
                if gap > pause || current.count >= maxWords || length > maxSeconds || sentenceEnd { flush() }
            }
            current.append(word)
        }
        flush()
        return segments
    }
}

extension ProjectSession {
    /// Transcribes the audio of a clip and returns the command that puts captions on the timeline.
    public func autoCaptionsCommand(forClip clipID: UUID, locale: Locale = .current, style: TextStyle = .caption,
                                    animation: TextAnimation = .karaoke) async throws -> EditCommand {
        guard let location = engine.project.locateClip(clipID) else { throw EditError.clipNotFound(clipID) }
        let sequence = engine.project.sequences[location.sequence]
        let clip = sequence.tracks[location.track].clips[location.clip]
        guard let asset = engine.project.asset(clip.assetID), asset.metadata.hasAudio, let url = resolver.url(for: asset) else {
            throw ServiceError.invalid("Choose a clip that has sound.")
        }
        let segments = try await SpeechTranscriber.transcribe(url, locale: locale)
        // Map source time to timeline time and keep only what falls inside the clip.
        func timeline(_ source: RationalTime) -> RationalTime {
            let local = source - clip.sourceStart
            return clip.start + (clip.speed == 1 ? local : local.scaled(by: 1 / clip.speed))
        }
        let placed = segments.compactMap { segment -> CaptionSegment? in
            let start = timeline(segment.start), end = timeline(segment.end)
            guard end > clip.start, start < clip.end else { return nil }
            let words = segment.words.map { TimedWord(text: $0.text, start: timeline($0.start), end: timeline($0.end)) }
            return CaptionSegment(start: RationalTime.max(start, clip.start), end: RationalTime.min(end, clip.end), text: segment.text, words: words)
        }
        guard !placed.isEmpty else { throw ServiceError.invalid("No speech was found in this clip.") }
        let track = sequence.tracks.first { $0.kind == .caption }?.id ?? UUID()
        return .replaceCaptions(sequenceID: sequence.id, trackID: track, segments: placed, style: style, animation: animation)
    }
}
