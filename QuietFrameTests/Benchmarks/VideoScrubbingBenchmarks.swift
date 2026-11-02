import AVFoundation
import UniformTypeIdentifiers
import XCTest
@testable import QuietFrame

/// The video scrubber's frame strip for a 3 s 720p clip played from its encrypted file, filled the way the viewer
/// fills it: a new reader, stream and player per visit, and frames requested once the player is attached.
@MainActor
final class VideoScrubbingBenchmarks: XCTestCase {
    private let frameCount = 12
    private let clipDuration: TimeInterval = 3

    func testFillingTheScrubberFrameStrip() throws {
        try measureFillingTheFrameStrip(keepsTheMainThreadBusy: false)
    }

    /// The main thread is busy in 4 ms bursts, as while the chrome fades or a page changes.
    func testFillingTheScrubberFrameStripWhileTheMainThreadIsBusy() throws {
        try measureFillingTheFrameStrip(keepsTheMainThreadBusy: true)
    }

    /// Back to a video whose strip was filled earlier in the same viewer, through the new stream and player a
    /// rebuilt page makes. The attachment lists how many frames each iteration showed as soon as it asked.
    func testReturningToAVideoFrameStrip() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let playback = ViewerVideoPlayback()
        let mediaID = UUID()
        try fillFrames(fixture, playback: playback, mediaID: mediaID)
        var framesShownAtOnce: [Int] = []

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let stream: EncryptedVideoStream
            do {
                stream = try attachNewStream(fixture, to: playback, mediaID: mediaID)
            } catch {
                XCTFail("Could not open the video: \(error)")
                return
            }
            startMeasuring()
            playback.requestFrames(count: frameCount)
            framesShownAtOnce.append(playback.frames.count)
            runBenchmark { try await self.waitForFrames(playback) }
            stopMeasuring()
            XCTAssertEqual(playback.frames.count, frameCount)
            playback.detach(mediaID: mediaID)
            stream.invalidate()
        }
        playback.release()

        let attachment = XCTAttachment(string: framesShownAtOnce.map { String($0) }.joined(separator: ","))
        attachment.name = "metric:framesShownAtOnce"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func measureFillingTheFrameStrip(keepsTheMainThreadBusy: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let playback = ViewerVideoPlayback()
            let mediaID = UUID()
            let stream: EncryptedVideoStream
            do {
                stream = try attachNewStream(fixture, to: playback, mediaID: mediaID)
            } catch {
                XCTFail("Could not open the video: \(error)")
                return
            }
            var busyMainThread: Timer?
            if keepsTheMainThreadBusy {
                let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
                    _ = usleep(4_000)
                }
                RunLoop.main.add(timer, forMode: .common)
                busyMainThread = timer
            }
            startMeasuring()
            playback.requestFrames(count: frameCount)
            runBenchmark { try await self.waitForFrames(playback) }
            stopMeasuring()
            busyMainThread?.invalidate()
            XCTAssertEqual(playback.frames.count, frameCount)
            playback.release()
            stream.invalidate()
        }
    }

    private struct Fixture {
        let vault: BenchmarkVault
        let identifier: String

        func remove() {
            vault.remove()
        }
    }

    /// A 3 s 1280x720 H.264 clip of noisy frames, stored encrypted with the production chunk size.
    private func makeFixture() throws -> Fixture {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        do {
            let identifier: String = try awaitBenchmark {
                let url = vault.directory.appendingPathComponent("clip.mov")
                try await TestVideoWriter.writeVideo(
                    to: url,
                    width: 1_280,
                    height: 720,
                    frameCount: 90,
                    framesPerSecond: 30,
                    seed: 36
                )
                let stored = try await vault.storage.store(plaintextURL: url, location: .media, progress: nil)
                try FileManager.default.removeItem(at: url)
                return stored.identifier
            }
            return Fixture(vault: vault, identifier: identifier)
        } catch {
            vault.remove()
            throw error
        }
    }

    /// A new reader, stream and player for the stored clip, attached the way a video page attaches them.
    private func attachNewStream(
        _ fixture: Fixture,
        to playback: ViewerVideoPlayback,
        mediaID: UUID
    ) throws -> EncryptedVideoStream {
        let reader = try awaitBenchmark {
            try await fixture.vault.storage.openEncryptedReader(identifier: fixture.identifier, location: .media)
        }
        let stream = try EncryptedVideoStream(reader: reader, contentTypeIdentifier: UTType.quickTimeMovie.identifier)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: stream.asset))
        playback.attach(player: player, asset: stream.asset, mediaID: mediaID, fallbackDuration: clipDuration)
        return stream
    }

    private func fillFrames(_ fixture: Fixture, playback: ViewerVideoPlayback, mediaID: UUID) throws {
        let stream = try attachNewStream(fixture, to: playback, mediaID: mediaID)
        defer {
            playback.detach(mediaID: mediaID)
            stream.invalidate()
        }
        playback.requestFrames(count: frameCount)
        try awaitBenchmark { try await self.waitForFrames(playback) }
    }

    private func waitForFrames(_ playback: ViewerVideoPlayback) async throws {
        let deadline = Date().addingTimeInterval(60)
        while playback.frames.count < frameCount {
            guard Date() < deadline else { throw BenchmarkError.timedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
