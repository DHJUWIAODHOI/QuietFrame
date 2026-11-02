import AVFoundation
import UniformTypeIdentifiers
import XCTest
@testable import QuietFrame

/// The video transport against a real 2 s H.264 clip in a temporary directory.
@MainActor
final class ViewerVideoClipTests: XCTestCase {
    private let clipDuration: TimeInterval = 2

    func testFramesFillTheStripFromTheEncryptedFileInMemory() async throws {
        let vault = try await BenchmarkVault.make()
        defer { vault.remove() }
        let clipURL = vault.directory.appendingPathComponent("clip.mov")
        try await TestVideoWriter.writeVideo(to: clipURL, frameCount: 60, framesPerSecond: 30)
        let identifier = try await vault.storage.store(plaintextURL: clipURL, location: .media, progress: nil).identifier
        try FileManager.default.removeItem(at: clipURL)
        let reader = try await vault.storage.openEncryptedReader(identifier: identifier, location: .media)
        let stream = try EncryptedVideoStream(reader: reader, contentTypeIdentifier: UTType.quickTimeMovie.identifier)
        defer { stream.invalidate() }
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        let player = AVPlayer(playerItem: AVPlayerItem(asset: stream.asset))
        playback.attach(player: player, asset: stream.asset, mediaID: mediaID, fallbackDuration: clipDuration)

        playback.requestFrames(count: 6)
        try await waitUntil { playback.frames.count == 6 }

        XCTAssertEqual(playback.frames.count, 6)
        for frame in playback.frames {
            XCTAssertLessThanOrEqual(max(frame.size.width, frame.size.height), 120)
        }
        for path in ["Caches/QuietFrameTemporary", "ApplicationSupport/QuietFrameVault/staging"] {
            let leftovers = try FileManager.default.contentsOfDirectory(
                atPath: vault.directory.appendingPathComponent(path).path
            )
            XCTAssertEqual(leftovers, [], "\(path) must stay empty while the strip fills")
        }
        playback.detach(mediaID: mediaID)
    }

    func testRequestingAnotherCountReplacesTheStripBeingFilled() async throws {
        let clipURL = try await makeClip()
        defer { removeClip(at: clipURL) }
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        attachClip(clipURL, to: playback, mediaID: mediaID)

        playback.requestFrames(count: 6)
        playback.requestFrames(count: 7)
        try await waitUntil { playback.frames.count >= 7 }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(playback.frames.count, 7)
        playback.detach(mediaID: mediaID)
    }

    func testDetachingMidFillPublishesNothingLate() async throws {
        let clipURL = try await makeClip()
        defer { removeClip(at: clipURL) }
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        attachClip(clipURL, to: playback, mediaID: mediaID)

        playback.requestFrames(count: 6)
        playback.detach(mediaID: mediaID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertTrue(playback.frames.isEmpty)

        attachClip(clipURL, to: playback, mediaID: mediaID)
        playback.requestFrames(count: 6)
        XCTAssertTrue(playback.frames.isEmpty, "An unfinished strip is not kept")
        try await waitUntil { playback.frames.count == 6 }
        playback.detach(mediaID: mediaID)
    }

    func testReturningToAVideoShowsItsKeptFramesAtOnce() async throws {
        let clipURL = try await makeClip()
        defer { removeClip(at: clipURL) }
        let playback = ViewerVideoPlayback()
        let videoID = UUID()
        let otherID = UUID()
        attachClip(clipURL, to: playback, mediaID: videoID)
        playback.requestFrames(count: 6)
        try await waitUntil { playback.frames.count == 6 }
        let filledFrames = playback.frames
        playback.detach(mediaID: videoID)
        attachClip(clipURL, to: playback, mediaID: otherID)
        playback.detach(mediaID: otherID)

        attachClip(clipURL, to: playback, mediaID: videoID)
        playback.requestFrames(count: 6)

        XCTAssertEqual(playback.frames.count, 6)
        XCTAssertTrue(zip(playback.frames, filledFrames).allSatisfy { pair in pair.0 === pair.1 })
        playback.release()
    }

    func testAChangedFrameCountDecodesAgain() async throws {
        let clipURL = try await makeClip()
        defer { removeClip(at: clipURL) }
        let playback = ViewerVideoPlayback()
        let videoID = UUID()
        attachClip(clipURL, to: playback, mediaID: videoID)
        playback.requestFrames(count: 6)
        try await waitUntil { playback.frames.count == 6 }
        playback.detach(mediaID: videoID)

        attachClip(clipURL, to: playback, mediaID: videoID)
        playback.requestFrames(count: 7)

        XCTAssertTrue(playback.frames.isEmpty)
        try await waitUntil { playback.frames.count == 7 }
        playback.release()
    }

    func testOnlyTheLastThreeStripsAreKept() async throws {
        let clipURL = try await makeClip()
        defer { removeClip(at: clipURL) }
        let playback = ViewerVideoPlayback()
        let videoIDs = [UUID(), UUID(), UUID(), UUID()]
        for videoID in videoIDs {
            attachClip(clipURL, to: playback, mediaID: videoID)
            playback.requestFrames(count: 6)
            try await waitUntil { playback.frames.count == 6 }
            playback.detach(mediaID: videoID)
        }

        attachClip(clipURL, to: playback, mediaID: videoIDs[0])
        playback.requestFrames(count: 6)
        XCTAssertTrue(playback.frames.isEmpty, "The least recently shown strip is no longer kept")
        playback.detach(mediaID: videoIDs[0])

        attachClip(clipURL, to: playback, mediaID: videoIDs[3])
        playback.requestFrames(count: 6)
        XCTAssertEqual(playback.frames.count, 6)
        playback.release()
    }

    func testReleaseForgetsKeptFrames() async throws {
        let clipURL = try await makeClip()
        defer { removeClip(at: clipURL) }
        let playback = ViewerVideoPlayback()
        let videoID = UUID()
        attachClip(clipURL, to: playback, mediaID: videoID)
        playback.requestFrames(count: 6)
        try await waitUntil { playback.frames.count == 6 }
        playback.detach(mediaID: videoID)

        playback.release()
        attachClip(clipURL, to: playback, mediaID: videoID)
        playback.requestFrames(count: 6)

        XCTAssertTrue(playback.frames.isEmpty)
        playback.release()
    }

    func testUndecodableVideoKeepsThePlaceholders() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.mov")
        try Benchmark.randomData(byteCount: 200_000, seed: 36).write(to: url)
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        attachClip(url, to: playback, mediaID: mediaID)

        playback.requestFrames(count: 6)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(playback.frames.isEmpty)
        playback.detach(mediaID: mediaID)
    }

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

    /// A new asset and player over the file, as a rebuilt video page makes them.
    private func attachClip(_ url: URL, to playback: ViewerVideoPlayback, mediaID: UUID) {
        let asset = AVURLAsset(url: url)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        playback.attach(player: player, asset: asset, mediaID: mediaID, fallbackDuration: clipDuration)
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
