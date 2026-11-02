import AVFoundation
import CoreVideo
import UniformTypeIdentifiers
import XCTest
@testable import QuietFrame

@MainActor
final class EncryptedStreamingTests: XCTestCase {
    private let chunkByteCount = 65_536

    func testRandomReadsMatchThePlaintext() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let plaintext = Benchmark.randomData(byteCount: 300_000, seed: 21)
        let identifier = try await fixture.store(plaintext)

        let reader = try await fixture.storage.openEncryptedReader(identifier: identifier, location: .media)

        XCTAssertEqual(reader.plaintextByteCount, 300_000)
        for (offset, length) in [(0, 10), (65_530, 20), (131_000, 70_000), (299_990, 10), (299_990, 100), (0, 300_000)] {
            let read = try await reader.read(offset: Int64(offset), length: length)
            let end = min(offset + length, plaintext.count)
            XCTAssertEqual(read, plaintext[offset..<end], "offset \(offset), length \(length)")
        }
        let pastTheEnd = try await reader.read(offset: 300_000, length: 10)
        XCTAssertTrue(pastTheEnd.isEmpty)
    }

    func testTamperedChunkFailsWhileTheOthersStillRead() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let plaintext = Benchmark.randomData(byteCount: 200_000, seed: 22)
        let identifier = try await fixture.store(plaintext)
        let url = fixture.encryptedURL(identifier)
        var container = try Data(contentsOf: url)
        let tamperedOffset = 48 + (chunkByteCount + 16) + 100
        container[tamperedOffset] ^= 0x01
        try container.write(to: url)

        let reader = try await fixture.storage.openEncryptedReader(identifier: identifier, location: .media)

        let firstChunk = try await reader.read(offset: 0, length: 1_000)
        XCTAssertEqual(firstChunk, plaintext[0..<1_000])
        do {
            _ = try await reader.read(offset: Int64(chunkByteCount) + 10, length: 10)
            XCTFail("A tampered chunk must not decrypt")
        } catch {
            XCTAssertEqual(error as? VaultError, .corruptedFile)
        }
    }

    func testTruncatedOrPaddedFilesAreRejectedOnOpen() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let identifier = try await fixture.store(Benchmark.randomData(byteCount: 100_000, seed: 23))
        let url = fixture.encryptedURL(identifier)
        let container = try Data(contentsOf: url)

        for damaged in [container.dropLast(), container + Data([0])] {
            try Data(damaged).write(to: url)
            do {
                _ = try await fixture.storage.openEncryptedReader(identifier: identifier, location: .media)
                XCTFail("A container whose size does not match its header must be rejected")
            } catch {
                XCTAssertEqual(error as? VaultError, .corruptedFile)
            }
        }
    }

    func testReadsStopWhenTheVaultLocks() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let identifier = try await fixture.store(Benchmark.randomData(byteCount: 200_000, seed: 24))
        let reader = try await fixture.storage.openEncryptedReader(identifier: identifier, location: .media)
        _ = try await reader.read(offset: 0, length: 10)

        await fixture.session.lock()

        for offset in [0, chunkByteCount * 2] {
            do {
                _ = try await reader.read(offset: Int64(offset), length: 10)
                XCTFail("Reads must stop once the vault locks (offset \(offset))")
            } catch {
                XCTAssertEqual(error as? VaultError, .authenticationRequired)
            }
        }
    }

    func testOversizedHeaderSizeIsRejectedOnOpen() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let identifier = try await fixture.store(Benchmark.randomData(byteCount: 100_000, seed: 25))
        let url = fixture.encryptedURL(identifier)
        var container = try Data(contentsOf: url)
        container.replaceSubrange(16..<24, with: Data(repeating: 0xFF, count: 8))
        try container.write(to: url)

        do {
            _ = try await fixture.storage.openEncryptedReader(identifier: identifier, location: .media)
            XCTFail("A plaintext size near UInt64.max must be rejected")
        } catch {
            XCTAssertEqual(error as? VaultError, .corruptedFile)
        }
    }

    func testVideoPlaysFromTheEncryptedFile() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let videoURL = fixture.directory.appendingPathComponent("clip.mov")
        try await TestVideoWriter.writeVideo(to: videoURL, frameCount: 30, framesPerSecond: 30)
        let videoSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber)
        XCTAssertGreaterThan(videoSize.intValue, chunkByteCount * 2, "The clip spans several chunks")
        let identifier = try await fixture.storage.store(plaintextURL: videoURL, location: .media, progress: nil).identifier
        let reader = try await fixture.storage.openEncryptedReader(identifier: identifier, location: .media)
        let stream = try EncryptedVideoStream(
            reader: reader,
            contentTypeIdentifier: UTType.quickTimeMovie.identifier,
            responseByteCount: 40_000
        )
        defer { stream.invalidate() }

        let duration = try await stream.asset.load(.duration)
        let tracks = try await stream.asset.loadTracks(withMediaType: .video)
        let generator = AVAssetImageGenerator(asset: stream.asset)
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))

        XCTAssertEqual(duration.seconds, 1, accuracy: 0.1)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(frame.image.width, 160)
        XCTAssertEqual(stream.asset.url.scheme, EncryptedVideoResourceLoader.scheme)
        XCTAssertFalse(stream.asset.url.absoluteString.contains(identifier))
        for path in ["Caches/QuietFrameTemporary", "QuietFrameVault/staging"] {
            let leftovers = try FileManager.default.contentsOfDirectory(
                atPath: fixture.directory.appendingPathComponent(path).path
            )
            XCTAssertEqual(leftovers, [], "\(path) must stay empty while a video plays")
        }
    }

    private struct Fixture {
        let directory: URL
        let session: VaultSession
        let storage: SecureFileStorageService

        func store(_ data: Data) async throws -> String {
            let url = directory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            return try await storage.store(plaintextURL: url, location: .media, progress: nil).identifier
        }

        func encryptedURL(_ identifier: String) -> URL {
            directory
                .appendingPathComponent("QuietFrameVault/media", isDirectory: true)
                .appendingPathComponent("\(identifier).qfe")
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let directory = try Benchmark.temporaryDirectory()
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x3C, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session, chunkByteCount: chunkByteCount),
            baseURL: directory,
            temporaryBaseURL: directory.appendingPathComponent("Caches", isDirectory: true),
            applyFileProtection: false
        )
        return Fixture(directory: directory, session: session, storage: storage)
    }
}
