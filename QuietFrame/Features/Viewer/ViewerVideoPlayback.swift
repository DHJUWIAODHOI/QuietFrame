import AVFoundation
import Foundation
import Observation
import UIKit

/// The playback position for a scrubber fraction, clamped to the video.
func playbackTime(forFraction fraction: Double, duration: TimeInterval) -> TimeInterval {
    guard duration.isFinite, duration > 0, fraction.isFinite else { return 0 }
    return min(max(fraction, 0), 1) * duration
}

/// How far through the video `time` is, from 0 to 1.
func playbackFraction(at time: TimeInterval, duration: TimeInterval) -> Double {
    guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
    return min(max(time / duration, 0), 1)
}

/// The moments the scrubber's frames are taken from: the middle of each of `count` equal slices.
func videoFrameTimes(count: Int, duration: TimeInterval) -> [TimeInterval] {
    guard count > 0, duration.isFinite, duration > 0 else { return [] }
    let slice = duration / Double(count)
    return (0..<count).map { (Double($0) + 0.5) * slice }
}

/// How many frames fill a scrubber strip of `width` points.
func videoFrameCount(forStripWidth width: CGFloat) -> Int {
    guard width.isFinite, width > 0 else { return 6 }
    return max(6, Int(width / 28.5))
}

/// Transport for the selected video: the page that owns the player attaches it, the chrome drives it.
@MainActor
@Observable
final class ViewerVideoPlayback {
    private struct FrameRequest: Equatable {
        let mediaID: UUID
        let count: Int
    }

    private(set) var mediaID: UUID?
    /// What the user asked for; scrubbing pauses the player without changing it.
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var frames: [UIImage] = []
    private(set) var isScrubbing = false
    /// A video that could not be prepared or played, so the transport offers no playback for it.
    private(set) var unavailableMediaID: UUID?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var frameAsset: AVAsset?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var frameRequest: FrameRequest?
    @ObservationIgnored private var frameTask: Task<Void, Never>?

    func attach(player newPlayer: AVPlayer, asset: AVAsset, mediaID newMediaID: UUID, fallbackDuration: TimeInterval?) {
        guard player !== newPlayer || mediaID != newMediaID else { return }
        stopObserving()
        player = newPlayer
        frameAsset = asset
        mediaID = newMediaID
        if unavailableMediaID == newMediaID { unavailableMediaID = nil }
        isScrubbing = false
        frames = []
        duration = Self.itemDuration(of: newPlayer) ?? max(fallbackDuration ?? 0, 0)
        currentTime = Self.validSeconds(newPlayer.currentTime()) ?? 0
        isReady = newPlayer.currentItem?.status == .readyToPlay
        if isPlaying {
            newPlayer.play()
        }
        observeTime(of: newPlayer)
    }

    /// Releases the player of `detachedID`; does nothing when another item is attached.
    func detach(mediaID detachedID: UUID) {
        guard mediaID == detachedID else { return }
        player?.pause()
        stopObserving()
        player = nil
        frameAsset = nil
        mediaID = nil
        if isPlaying { isPlaying = false }
        isReady = false
        isScrubbing = false
        currentTime = 0
        duration = 0
        if !frames.isEmpty { frames = [] }
    }

    /// Lets go of whatever is attached, for when the viewer goes away before its video page cleans up.
    func release() {
        guard let mediaID else { return }
        detach(mediaID: mediaID)
    }

    func markUnavailable(mediaID failedID: UUID) {
        if unavailableMediaID != failedID { unavailableMediaID = failedID }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Before a player is attached this only records the intent; `attach` starts playback.
    func play() {
        if !isPlaying { isPlaying = true }
        if !isScrubbing {
            player?.play()
        }
    }

    func pause() {
        if isPlaying { isPlaying = false }
        if isScrubbing { isScrubbing = false }
        player?.pause()
    }

    func scrub(toFraction fraction: Double) {
        guard let player else { return }
        if !isScrubbing {
            isScrubbing = true
            player.pause()
        }
        seek(player, to: playbackTime(forFraction: fraction, duration: duration))
    }

    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        if isPlaying {
            player?.play()
        }
    }

    func seek(by seconds: TimeInterval) {
        guard let player, seconds.isFinite else { return }
        seek(player, to: min(max(currentTime + seconds, 0), duration))
    }

    /// Decodes `count` small frames of the attached video in memory, one at a time. Nothing is written to disk.
    func requestFrames(count: Int) {
        guard let mediaID, let frameAsset, count > 0 else { return }
        let request = FrameRequest(mediaID: mediaID, count: count)
        guard frameRequest != request else { return }
        frameTask?.cancel()
        frameTask = nil
        if !frames.isEmpty { frames = [] }
        let times = videoFrameTimes(count: count, duration: duration)
        guard !times.isEmpty else {
            frameRequest = nil
            return
        }
        frameRequest = request
        frameTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: frameAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 120, height: 120)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            for time in times {
                guard !Task.isCancelled, self != nil else { return }
                do {
                    let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                    guard !Task.isCancelled, let self else { return }
                    self.appendFrame(UIImage(cgImage: frame.image), for: request)
                } catch {
                    return
                }
            }
        }
    }

    private func appendFrame(_ frame: UIImage, for request: FrameRequest) {
        guard frameRequest == request else { return }
        frames.append(frame)
    }

    private func seek(_ player: AVPlayer, to seconds: TimeInterval) {
        currentTime = seconds
        guard player.currentItem != nil else { return }
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func observeTime(of player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playerTimeDidChange(time)
            }
        }
    }

    private func playerTimeDidChange(_ time: CMTime) {
        guard let player else { return }
        if !isScrubbing, let seconds = Self.validSeconds(time), seconds != currentTime {
            currentTime = seconds
        }
        let ready = player.currentItem?.status == .readyToPlay
        if ready != isReady {
            isReady = ready
        }
        if let itemDuration = Self.itemDuration(of: player), itemDuration != duration {
            duration = itemDuration
        }
        let hasFailed = player.status == .failed || player.currentItem?.status == .failed
        if hasFailed, let mediaID {
            markUnavailable(mediaID: mediaID)
        }
        // The observer also fires when playback stops, so an interruption or route change ends the intent too.
        if isPlaying, !isScrubbing, hasFailed || player.rate == 0 {
            isPlaying = false
        }
    }

    private func stopObserving() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        frameTask?.cancel()
        frameTask = nil
        frameRequest = nil
    }

    private static func itemDuration(of player: AVPlayer) -> TimeInterval? {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func validSeconds(_ time: CMTime) -> TimeInterval? {
        guard time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite ? max(seconds, 0) : nil
    }
}
