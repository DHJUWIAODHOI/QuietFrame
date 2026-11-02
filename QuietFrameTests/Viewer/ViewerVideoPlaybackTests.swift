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

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
