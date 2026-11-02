import AVFoundation
import XCTest
@testable import QuietFrame

/// The video transport against a real 2 s H.264 clip in a temporary directory.
@MainActor
final class ViewerVideoClipTests: XCTestCase {
    private let clipDuration: TimeInterval = 2

    /// Only the first position goes out at once; the last one has to follow from the first seek's completion.
    func testScrubbingAPlayerChasesToTheLastPositionBeforeRelease() async throws {
        let clipURL = try await makeClip()
        defer { removeClip(at: clipURL) }
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        let asset = AVURLAsset(url: clipURL)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        playback.attach(player: player, asset: asset, mediaID: mediaID, fallbackDuration: clipDuration)
        try await waitUntil { player.currentItem?.status == .readyToPlay }

        playback.scrub(toFraction: 0.1)
        playback.scrub(toFraction: 0.5)
        playback.scrub(toFraction: 0.9)
        try await waitUntil { abs(player.currentTime().seconds - 1.8) < 0.01 }

        XCTAssertTrue(playback.isScrubbing)
        XCTAssertEqual(playback.currentTime, 1.8, accuracy: 0.001)
        playback.endScrub()
        XCTAssertEqual(player.currentTime().seconds, 1.8, accuracy: 0.01)
        playback.detach(mediaID: mediaID)
    }

    private func makeClip() async throws -> URL {
        let directory = try Benchmark.temporaryDirectory()
        let url = directory.appendingPathComponent("clip.mov")
        do {
            try await TestVideoWriter.writeVideo(to: url, frameCount: 60, framesPerSecond: 30)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }

    private func removeClip(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the video")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
