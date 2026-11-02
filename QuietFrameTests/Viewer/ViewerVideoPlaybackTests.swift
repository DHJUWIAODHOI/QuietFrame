import AVFoundation
import XCTest
@testable import QuietFrame

@MainActor
final class ViewerVideoPlaybackTests: XCTestCase {
    func testScrubFractionMapsToPlaybackTimeAndBack() {
        XCTAssertEqual(playbackTime(forFraction: 0.25, duration: 40), 10, accuracy: 0.001)
        XCTAssertEqual(playbackFraction(at: 10, duration: 40), 0.25, accuracy: 0.001)
        XCTAssertEqual(playbackFraction(at: playbackTime(forFraction: 0.6, duration: 42), duration: 42), 0.6, accuracy: 0.001)
    }

    func testScrubFractionIsClampedToTheVideo() {
        XCTAssertEqual(playbackTime(forFraction: -0.5, duration: 40), 0, accuracy: 0.001)
        XCTAssertEqual(playbackTime(forFraction: 1.5, duration: 40), 40, accuracy: 0.001)
        XCTAssertEqual(playbackFraction(at: -3, duration: 40), 0, accuracy: 0.001)
        XCTAssertEqual(playbackFraction(at: 90, duration: 40), 1, accuracy: 0.001)
    }

    func testZeroDurationMapsEverythingToTheStart() {
        XCTAssertEqual(playbackTime(forFraction: 0.5, duration: 0), 0, accuracy: 0.001)
        XCTAssertEqual(playbackTime(forFraction: .nan, duration: 40), 0, accuracy: 0.001)
        XCTAssertEqual(playbackFraction(at: 5, duration: 0), 0, accuracy: 0.001)
        XCTAssertEqual(playbackFraction(at: 5, duration: .nan), 0, accuracy: 0.001)
    }

    func testFrameTimesAreEvenlySpacedInsideTheVideo() {
        XCTAssertEqual(videoFrameTimes(count: 4, duration: 8), [1, 3, 5, 7])

        let times = videoFrameTimes(count: 12, duration: 42)

        XCTAssertEqual(times.count, 12)
        XCTAssertTrue(times.allSatisfy { $0 > 0 && $0 < 42 })
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertEqual(later - earlier, 3.5, accuracy: 0.001)
        }
    }

    func testNoFrameTimesWithoutFramesOrDuration() {
        XCTAssertEqual(videoFrameTimes(count: 0, duration: 42), [])
        XCTAssertEqual(videoFrameTimes(count: 12, duration: 0), [])
        XCTAssertEqual(videoFrameTimes(count: 12, duration: .infinity), [])
    }

    func testFrameCountFillsTheStrip() {
        XCTAssertEqual(videoFrameCount(forStripWidth: 342), 12)
        XCTAssertEqual(videoFrameCount(forStripWidth: 100), 6)
        XCTAssertEqual(videoFrameCount(forStripWidth: 0), 6)
        XCTAssertEqual(videoFrameCount(forStripWidth: .infinity), 6)
    }

    func testPlayBeforeAttachStartsTheAttachedVideo() {
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()

        playback.play()

        XCTAssertTrue(playback.isPlaying)
        XCTAssertNil(playback.mediaID)

        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 42)

        XCTAssertEqual(playback.mediaID, mediaID)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.duration, 42, accuracy: 0.001)
        playback.detach(mediaID: mediaID)
    }

    func testDetachIgnoresOtherItemsAndResetsTheTransport() {
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 42)
        playback.play()

        playback.detach(mediaID: UUID())

        XCTAssertEqual(playback.mediaID, mediaID)
        XCTAssertTrue(playback.isPlaying)

        playback.detach(mediaID: mediaID)

        XCTAssertNil(playback.mediaID)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.duration, 0, accuracy: 0.001)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
        XCTAssertTrue(playback.frames.isEmpty)
    }

    func testScrubbingMovesTheTimeAndKeepsThePlayIntent() {
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)
        playback.play()

        playback.scrub(toFraction: 0.25)

        XCTAssertTrue(playback.isScrubbing)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, 10, accuracy: 0.001)

        playback.endScrub()

        XCTAssertFalse(playback.isScrubbing)
        XCTAssertTrue(playback.isPlaying)
        playback.detach(mediaID: mediaID)
    }

    func testPausingEndsAScrub() {
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)
        playback.play()
        playback.scrub(toFraction: 0.5)

        playback.pause()

        XCTAssertFalse(playback.isScrubbing)
        XCTAssertFalse(playback.isPlaying)
        playback.detach(mediaID: mediaID)
    }

    func testFailedVideoStaysUnavailableUntilItAttaches() {
        let playback = ViewerVideoPlayback()
        let failedID = UUID()
        let otherID = UUID()

        playback.markUnavailable(mediaID: failedID)
        XCTAssertEqual(playback.unavailableMediaID, failedID)

        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: otherID, fallbackDuration: 10)
        XCTAssertEqual(playback.unavailableMediaID, failedID)

        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: failedID, fallbackDuration: 10)
        XCTAssertNil(playback.unavailableMediaID)
        playback.detach(mediaID: failedID)
    }

    func testReleaseLetsGoOfTheAttachedVideo() {
        let playback = ViewerVideoPlayback()
        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: UUID(), fallbackDuration: 30)
        playback.play()

        playback.release()

        XCTAssertNil(playback.mediaID)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.duration, 0, accuracy: 0.001)
    }

    func testScrubbingWithoutAPlayerIsIgnored() {
        let playback = ViewerVideoPlayback()

        playback.scrub(toFraction: 0.5)

        XCTAssertFalse(playback.isScrubbing)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
    }

    func testSeekingIsClampedToTheVideo() {
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        playback.attach(player: AVPlayer(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 20)

        playback.seek(by: 5)
        XCTAssertEqual(playback.currentTime, 5, accuracy: 0.001)

        playback.seek(by: -10)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)

        playback.seek(by: 60)
        XCTAssertEqual(playback.currentTime, 20, accuracy: 0.001)
        playback.detach(mediaID: mediaID)
    }

    func testSeekChaseSendsTheFirstPositionAtOnce() {
        var chase = VideoSeekChase()

        let sent = chase.request(4)

        XCTAssertEqual(sent, 4)
        XCTAssertTrue(chase.isSeeking)
        XCTAssertNil(chase.waitingTime)
    }

    func testSeekChaseKeepsOnlyTheNewestWaitingPosition() {
        var chase = VideoSeekChase()

        let first = chase.request(4)
        let second = chase.request(8)
        let third = chase.request(12)
        let afterFirstSeek = chase.seekDidFinish()
        let afterSecondSeek = chase.seekDidFinish()
        let nextDrag = chase.request(20)

        XCTAssertEqual(first, 4)
        XCTAssertNil(second)
        XCTAssertNil(third)
        XCTAssertEqual(afterFirstSeek, 12)
        XCTAssertNil(afterSecondSeek)
        XCTAssertEqual(nextDrag, 20)
    }

    func testSeekChaseFinishHandsBackTheUnsentPositionAndResets() {
        var chase = VideoSeekChase()
        _ = chase.request(4)
        _ = chase.request(8)

        let unsent = chase.finish()

        XCTAssertEqual(unsent, 8)
        XCTAssertEqual(chase, VideoSeekChase())
        let nextDrag = chase.request(1)
        XCTAssertEqual(nextDrag, 1)
        let nothingWaiting = chase.finish()
        XCTAssertNil(nothingWaiting)
    }

    func testScrubbingSendsOneSeekAtATimeAndEndsOnTheLastPosition() {
        let recorder = SeekRecorder()
        let playback = ViewerVideoPlayback(exactSeek: { player, seconds, completion in
            recorder.record(player, seconds, completion)
        })
        let mediaID = UUID()
        playback.attach(player: makePlayerWithItem(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)

        playback.scrub(toFraction: 0.1)
        playback.scrub(toFraction: 0.2)
        playback.scrub(toFraction: 0.3)

        assertSeeks(recorder, [4])
        XCTAssertEqual(playback.currentTime, 12, accuracy: 0.001)

        recorder.finishSeek(0)

        assertSeeks(recorder, [4, 12])

        playback.scrub(toFraction: 0.5)
        playback.endScrub()

        assertSeeks(recorder, [4, 12, 20])
        XCTAssertEqual(recorder.seek(at: 2)?.isChased, false, "The last position is sent directly on release")
        XCTAssertEqual(playback.currentTime, 20, accuracy: 0.001)

        recorder.finishSeek(1)

        assertSeeks(recorder, [4, 12, 20])
        playback.detach(mediaID: mediaID)
    }

    func testAFinishedSeekWithNothingWaitingLetsTheNextPositionGoAtOnce() {
        let recorder = SeekRecorder()
        let playback = ViewerVideoPlayback(exactSeek: { player, seconds, completion in
            recorder.record(player, seconds, completion)
        })
        let mediaID = UUID()
        playback.attach(player: makePlayerWithItem(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)

        playback.scrub(toFraction: 0.1)
        recorder.finishSeek(0)

        assertSeeks(recorder, [4])

        playback.scrub(toFraction: 0.2)

        assertSeeks(recorder, [4, 8])
        XCTAssertEqual(recorder.seek(at: 1)?.isChased, true)
        playback.detach(mediaID: mediaID)
    }

    func testReleasingOnTheLastSentPositionSendsNothingMore() {
        let recorder = SeekRecorder()
        let playback = ViewerVideoPlayback(exactSeek: { player, seconds, completion in
            recorder.record(player, seconds, completion)
        })
        let mediaID = UUID()
        playback.attach(player: makePlayerWithItem(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)
        playback.play()

        playback.scrub(toFraction: 0.25)

        assertSeeks(recorder, [10])

        playback.endScrub()

        assertSeeks(recorder, [10])
        XCTAssertFalse(playback.isScrubbing)
        XCTAssertTrue(playback.isPlaying)
        playback.detach(mediaID: mediaID)
    }

    func testPausingMidScrubSendsTheLastPosition() {
        let recorder = SeekRecorder()
        let playback = ViewerVideoPlayback(exactSeek: { player, seconds, completion in
            recorder.record(player, seconds, completion)
        })
        let mediaID = UUID()
        playback.attach(player: makePlayerWithItem(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)
        playback.play()

        playback.scrub(toFraction: 0.1)
        playback.scrub(toFraction: 0.4)

        assertSeeks(recorder, [4])

        playback.pause()

        assertSeeks(recorder, [4, 16])
        XCTAssertEqual(recorder.seek(at: 1)?.isChased, false)
        XCTAssertFalse(playback.isScrubbing)
        XCTAssertFalse(playback.isPlaying)
        playback.detach(mediaID: mediaID)
    }

    func testAccessibilityAdjustmentsSeekImmediately() {
        let recorder = SeekRecorder()
        let playback = ViewerVideoPlayback(exactSeek: { player, seconds, completion in
            recorder.record(player, seconds, completion)
        })
        let mediaID = UUID()
        playback.attach(player: makePlayerWithItem(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)

        playback.seek(by: 5)
        playback.seek(by: 5)
        playback.seek(by: 5)

        assertSeeks(recorder, [5, 10, 15])
        XCTAssertFalse(recorder.seeks.contains { $0.isChased })
        XCTAssertEqual(playback.currentTime, 15, accuracy: 0.001)
        playback.detach(mediaID: mediaID)
    }

    func testAnAccessibilityAdjustmentDuringAScrubIsNotUndoneByTheChase() {
        let recorder = SeekRecorder()
        let playback = ViewerVideoPlayback(exactSeek: { player, seconds, completion in
            recorder.record(player, seconds, completion)
        })
        let mediaID = UUID()
        playback.attach(player: makePlayerWithItem(), asset: AVURLAsset(url: makeURL()), mediaID: mediaID, fallbackDuration: 40)

        playback.scrub(toFraction: 0.1)
        playback.scrub(toFraction: 0.3)
        playback.seek(by: 5)
        recorder.finishSeek(0)
        playback.endScrub()

        assertSeeks(recorder, [4, 17])
        XCTAssertEqual(playback.currentTime, 17, accuracy: 0.001)
        playback.detach(mediaID: mediaID)
    }

    func testAttachingAnotherVideoAbandonsTheChase() {
        let recorder = SeekRecorder()
        let playback = ViewerVideoPlayback(exactSeek: { player, seconds, completion in
            recorder.record(player, seconds, completion)
        })
        let firstPlayer = makePlayerWithItem()
        let secondID = UUID()
        playback.attach(player: firstPlayer, asset: AVURLAsset(url: makeURL()), mediaID: UUID(), fallbackDuration: 40)
        playback.scrub(toFraction: 0.1)
        playback.scrub(toFraction: 0.2)

        playback.attach(player: makePlayerWithItem(), asset: AVURLAsset(url: makeURL()), mediaID: secondID, fallbackDuration: 40)
        recorder.finishSeek(0)

        assertSeeks(recorder, [4])
        XCTAssertTrue(recorder.seek(at: 0)?.player === firstPlayer)
        XCTAssertFalse(playback.isScrubbing)
        playback.detach(mediaID: secondID)
    }

    private func assertSeeks(
        _ recorder: SeekRecorder,
        _ expected: [TimeInterval],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sent = recorder.seeks.map { $0.seconds }
        XCTAssertEqual(sent.count, expected.count, "Seeks sent: \(sent)", file: file, line: line)
        for (seconds, expectedSeconds) in zip(sent, expected) {
            XCTAssertEqual(seconds, expectedSeconds, accuracy: 0.001, "Seeks sent: \(sent)", file: file, line: line)
        }
    }

    /// A player with an item, so scrubbing reaches the seek seam; the item's file does not exist.
    private func makePlayerWithItem() -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(url: makeURL()))
    }

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

/// Records the seeks the transport sends instead of sending them, and finishes them when a test says so.
@MainActor
private final class SeekRecorder {
    struct Seek {
        let player: AVPlayer
        let seconds: TimeInterval
        let completion: (@MainActor @Sendable () -> Void)?

        var isChased: Bool {
            completion != nil
        }
    }

    private(set) var seeks: [Seek] = []

    func record(_ player: AVPlayer, _ seconds: TimeInterval, _ completion: (@MainActor @Sendable () -> Void)?) {
        seeks.append(Seek(player: player, seconds: seconds, completion: completion))
    }

    func seek(at index: Int) -> Seek? {
        seeks.indices.contains(index) ? seeks[index] : nil
    }

    func finishSeek(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard seeks.indices.contains(index) else {
            XCTFail("Seek \(index) was never sent", file: file, line: line)
            return
        }
        let completion = seeks[index].completion
        completion?()
    }
}
