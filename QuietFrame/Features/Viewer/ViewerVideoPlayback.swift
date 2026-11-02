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

private let keptFrameStripLimit = 3

/// Scrubbing keeps one exact seek in flight; only the latest position waits for it.
struct VideoSeekChase: Equatable {
    private(set) var isSeeking = false
    private(set) var waitingTime: TimeInterval?

    mutating func request(_ time: TimeInterval) -> TimeInterval? {
        guard isSeeking else {
            isSeeking = true
            return time
        }
        waitingTime = time
        return nil
    }

    mutating func seekDidFinish() -> TimeInterval? {
        guard let next = waitingTime else {
            isSeeking = false
            return nil
        }
        waitingTime = nil
        return next
    }

    mutating func finish() -> TimeInterval? {
        let waiting = waitingTime
        self = VideoSeekChase()
        return waiting
    }
}

/// Puts frames into the scrubber strip from left to right, whatever order they arrive in.
struct FrameStripAssembly<Time: Equatable, Frame> {
    private let times: [Time]
    private var waitingSlots: [Int]
    private var arrivedFrames: [Int: Frame] = [:]
    private var end: Int
    private var publishedCount = 0

    init(times: [Time]) {
        self.times = times
        waitingSlots = Array(times.indices)
        end = times.count
    }

    var isFinished: Bool {
        publishedCount >= end
    }

    var isComplete: Bool {
        publishedCount == times.count
    }

    mutating func receive(_ frame: Frame?, requestedAt time: Time?) -> [Frame] {
        guard !waitingSlots.isEmpty else { return [] }
        var position = 0
        if let time, let match = waitingSlots.firstIndex(where: { times[$0] == time }) {
            position = match
        }
        let slot = waitingSlots.remove(at: position)
        if let frame {
            arrivedFrames[slot] = frame
        } else {
            end = min(end, slot)
        }
        var ready: [Frame] = []
        while publishedCount < end, let next = arrivedFrames.removeValue(forKey: publishedCount) {
            ready.append(next)
            publishedCount += 1
        }
        return ready
    }
}

/// Transport for the selected video: the page that owns the player attaches it, the chrome drives it.
@MainActor
@Observable
final class ViewerVideoPlayback {
    /// Sends one exact seek; the completion runs once the seek has finished or been replaced.
    typealias ExactSeek = @MainActor (AVPlayer, TimeInterval, (@MainActor @Sendable () -> Void)?) -> Void

    private struct FrameRequest: Equatable {
        let mediaID: UUID
        let count: Int
    }

    private struct KeptFrameStrip {
        let mediaID: UUID
        let times: [TimeInterval]
        let frames: [UIImage]
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

    private let exactSeek: ExactSeek
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var frameAsset: AVAsset?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var frameRequest: FrameRequest?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var frameGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var keptFrameStrips: [KeptFrameStrip] = []
    @ObservationIgnored private var seekChase = VideoSeekChase()
    /// Changes whenever a chase ends, so completions of its seeks that arrive later are ignored.
    @ObservationIgnored private var seekToken: UInt64 = 0

    init(exactSeek: @escaping ExactSeek = ViewerVideoPlayback.systemExactSeek) {
        self.exactSeek = exactSeek
    }

    /// AVPlayer does not document which queue runs a seek's completion. AVFoundation rejects a completion before the
    /// item is ready, and an exact seek to the very end may never complete, so those count as finished at once.
    static func systemExactSeek(
        _ player: AVPlayer,
        _ seconds: TimeInterval,
        _ completion: (@MainActor @Sendable () -> Void)?
    ) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let completion else {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        guard let item = player.currentItem,
              item.status == .readyToPlay,
              CMTimeCompare(time, item.duration) < 0 else {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            Task { @MainActor in
                completion()
            }
            return
        }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable (_: Bool) in
            Task { @MainActor in
                completion()
            }
        }
    }

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
        if let mediaID {
            detach(mediaID: mediaID)
        }
        keptFrameStrips.removeAll()
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
        if isScrubbing {
            isScrubbing = false
            finishChase()
        }
        player?.pause()
    }

    func scrub(toFraction fraction: Double) {
        guard let player else { return }
        if !isScrubbing {
            isScrubbing = true
            player.pause()
        }
        let seconds = playbackTime(forFraction: fraction, duration: duration)
        currentTime = seconds
        guard player.currentItem != nil, let next = seekChase.request(seconds) else { return }
        sendChasedSeek(player, to: next)
    }

    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        finishChase()
        if isPlaying {
            player?.play()
        }
    }

    /// Never chased: each adjustment starts from `currentTime`, which the time observer rewrites outside a scrub.
    func seek(by seconds: TimeInterval) {
        guard let player, seconds.isFinite else { return }
        abandonChase()
        seek(player, to: min(max(currentTime + seconds, 0), duration))
    }

    /// Decodes `count` small frames of the attached video in memory. Nothing is written to disk.
    func requestFrames(count: Int) {
        guard let mediaID, let frameAsset, count > 0 else { return }
        let request = FrameRequest(mediaID: mediaID, count: count)
        guard frameRequest != request else { return }
        cancelFrames()
        let times = videoFrameTimes(count: count, duration: duration)
        let kept = keptFrames(mediaID: mediaID, times: times)
        if !frames.isEmpty || kept != nil {
            frames = kept ?? []
        }
        guard !times.isEmpty else { return }
        frameRequest = request
        if kept == nil {
            generateFrames(for: request, times: times, asset: frameAsset)
        }
    }

    private func keptFrames(mediaID: UUID, times: [TimeInterval]) -> [UIImage]? {
        guard !times.isEmpty,
              let index = keptFrameStrips.firstIndex(where: { $0.mediaID == mediaID && $0.times == times })
        else { return nil }
        let strip = keptFrameStrips.remove(at: index)
        keptFrameStrips.append(strip)
        return strip.frames
    }

    private func generateFrames(for request: FrameRequest, times: [TimeInterval], asset: AVAsset) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let requestedTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        frameGenerator = generator
        frameTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            var assembly = FrameStripAssembly<CMTime, UIImage>(times: requestedTimes)
            for await result in generator.images(for: requestedTimes) {
                guard !Task.isCancelled, let self, self.frameRequest == request else { return }
                let ready: [UIImage]
                if case let .success(requestedTime, image, _) = result {
                    ready = assembly.receive(UIImage(cgImage: image), requestedAt: requestedTime)
                } else if case let .failure(requestedTime, _) = result {
                    ready = assembly.receive(nil, requestedAt: requestedTime)
                } else {
                    ready = assembly.receive(nil, requestedAt: nil)
                }
                if !ready.isEmpty {
                    self.frames.append(contentsOf: ready)
                }
                if assembly.isFinished {
                    self.finishFrames(for: request, times: times, isComplete: assembly.isComplete)
                    return
                }
            }
            guard !Task.isCancelled, let self, self.frameRequest == request else { return }
            self.finishFrames(for: request, times: times, isComplete: false)
        }
    }

    /// The request stays recorded, so a strip that stopped at a failure is decoded again only after a new attach.
    private func finishFrames(for request: FrameRequest, times: [TimeInterval], isComplete: Bool) {
        guard frameRequest == request else { return }
        frameGenerator?.cancelAllCGImageGeneration()
        frameGenerator = nil
        frameTask = nil
        guard isComplete else { return }
        keptFrameStrips.removeAll { $0.mediaID == request.mediaID }
        keptFrameStrips.append(KeptFrameStrip(mediaID: request.mediaID, times: times, frames: frames))
        if keptFrameStrips.count > keptFrameStripLimit {
            keptFrameStrips.removeFirst(keptFrameStrips.count - keptFrameStripLimit)
        }
    }

    /// The generator may not watch for task cancellation, so its pending images are cancelled directly.
    private func cancelFrames() {
        frameTask?.cancel()
        frameTask = nil
        frameGenerator?.cancelAllCGImageGeneration()
        frameGenerator = nil
        frameRequest = nil
    }

    private func seek(_ player: AVPlayer, to seconds: TimeInterval) {
        currentTime = seconds
        sendExactSeek(player, to: seconds)
    }

    private func sendExactSeek(_ player: AVPlayer, to seconds: TimeInterval) {
        guard player.currentItem != nil else { return }
        exactSeek(player, seconds, nil)
    }

    private func sendChasedSeek(_ player: AVPlayer, to seconds: TimeInterval) {
        let token = seekToken
        exactSeek(player, seconds, { [weak self] in
            self?.chasedSeekDidFinish(token: token)
        })
    }

    private func chasedSeekDidFinish(token: UInt64) {
        guard token == seekToken, let player, player.currentItem != nil,
              let next = seekChase.seekDidFinish() else { return }
        sendChasedSeek(player, to: next)
    }

    private func finishChase() {
        let waiting = seekChase.finish()
        seekToken &+= 1
        if let player, let waiting {
            sendExactSeek(player, to: waiting)
        }
    }

    private func abandonChase() {
        seekChase = VideoSeekChase()
        seekToken &+= 1
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
        cancelFrames()
        abandonChase()
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
