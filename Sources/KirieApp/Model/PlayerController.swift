import AVFoundation
import Foundation
import KirieServices
import MediaServices
import Observation
import ProjectDomain
import RenderEngine

enum PreviewQuality: String, CaseIterable, Identifiable {
    case full, half, quarter
    var id: String { rawValue }
    var scale: CGFloat {
        switch self {
        case .full: 1
        case .half: 0.5
        case .quarter: 0.25
        }
    }
    var label: String {
        switch self {
        case .full: "Full"
        case .half: "Half"
        case .quarter: "Quarter"
        }
    }
}

/// Owns the AVPlayer for the active timeline. Playback and frame stepping follow media timestamps,
/// never wall-clock timers.
@MainActor
@Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var currentTime: RationalTime = .zero
    private(set) var duration: RationalTime = .zero
    private(set) var isPlaying = false
    private(set) var hasContent = false
    private(set) var buildError: String?
    var frameRate: FrameRate = .fps30

    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var buildGeneration = 0
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = RationalTime(time).clamped(.zero, self.duration)
                if self.isPlaying, self.player.rate == 0 { self.isPlaying = false }
            }
        }
    }

    /// Rebuilds the playable composition for the current project state, keeping the playhead.
    func reload(session: ProjectSession, quality: PreviewQuality) {
        buildGeneration += 1
        let generation = buildGeneration
        let project = session.project
        let resolver = session.resolver
        let keep = currentTime
        frameRate = project.canvas.frameRate
        let sequenceDuration = project.activeSequence.duration
        guard sequenceDuration.isPositive else {
            player.replaceCurrentItem(with: nil)
            hasContent = false
            isPlaying = false
            duration = .zero
            currentTime = .zero
            buildError = nil
            return
        }
        // Even dimensions keep the hardware path happy at reduced quality.
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        let size = CGSize(width: even(CGFloat(project.canvas.width) * quality.scale), height: even(CGFloat(project.canvas.height) * quality.scale))
        Task {
            do {
                let built = try await CompositionBuilder.build(project: project, resolver: resolver, outputSize: size,
                                                               options: RenderOptions(excludeUnlicensedAudio: false))
                guard generation == self.buildGeneration else { return }
                let wasPlaying = self.isPlaying
                let item = built.makePlayerItem()
                self.player.replaceCurrentItem(with: item)
                self.duration = sequenceDuration
                self.hasContent = true
                self.buildError = nil
                let target = keep.clamped(.zero, sequenceDuration)
                await self.player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = target
                if wasPlaying { self.player.play() }
            } catch {
                guard generation == self.buildGeneration else { return }
                self.buildError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func togglePlay() {
        guard hasContent else { return }
        if isPlaying {
            pause()
        } else {
            // Play from the start when parked at the end.
            if currentTime >= duration - frameRate.frameDuration { seek(to: .zero) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: RationalTime) {
        let target = time.clamped(.zero, duration)
        currentTime = target
        player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int64) {
        pause()
        seek(to: (currentTime.rounded(toFrame: frameRate) + frameRate.frameDuration * frames))
    }

    /// J/K/L shuttle: negative rates play backwards.
    func shuttle(_ rate: Float) {
        guard hasContent else { return }
        if rate == 0 {
            pause()
        } else {
            player.rate = rate
            isPlaying = true
        }
    }
}
