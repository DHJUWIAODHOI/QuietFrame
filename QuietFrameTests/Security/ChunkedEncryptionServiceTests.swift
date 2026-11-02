import Foundation
import XCTest
@testable import QuietFrame

final class ChunkedEncryptionServiceTests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testRoundTripAcrossMultipleChunks() async throws {
        let directory = try XCTUnwrap(directory)
        let sourceURL = directory.appendingPathComponent("source.bin")
        let encryptedURL = directory.appendingPathComponent("encrypted.qfe")
        let decryptedURL = directory.appendingPathComponent("decrypted.bin")
        let source = Data((0..<180_000).map { UInt8($0 % 251) })
        try source.write(to: sourceURL)

        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x7a, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        let result = try await service.encryptFile(at: sourceURL, to: encryptedURL, progress: nil)
        try await service.decryptFile(at: encryptedURL, to: decryptedURL, progress: nil)

        XCTAssertEqual(result.plaintextByteCount, Int64(source.count))
        XCTAssertEqual(try Data(contentsOf: decryptedURL), source)
        XCTAssertNotEqual(try Data(contentsOf: encryptedURL), source)
    }

    func testTamperedCiphertextIsRejectedAndOutputRemoved() async throws {
        let directory = try XCTUnwrap(directory)
        let sourceURL = directory.appendingPathComponent("source.bin")
        let encryptedURL = directory.appendingPathComponent("encrypted.qfe")
        let outputURL = directory.appendingPathComponent("output.bin")
        try Data(repeating: 0x42, count: 70_000).write(to: sourceURL)

        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x17, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        _ = try await service.encryptFile(at: sourceURL, to: encryptedURL, progress: nil)

        var encrypted = try Data(contentsOf: encryptedURL)
        encrypted[encrypted.index(before: encrypted.endIndex)] ^= 0xff
        try encrypted.write(to: encryptedURL)

        do {
            try await service.decryptFile(at: encryptedURL, to: outputURL, progress: nil)
            XCTFail("Authenticated decryption must reject modified data.")
        } catch {
            XCTAssertEqual(error as? VaultError, .corruptedFile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testLockRevokesEncryptionAtNextChunkAndRemovesOutput() async throws {
        let directory = try XCTUnwrap(directory)
        let sourceURL = directory.appendingPathComponent("large-source.bin")
        let encryptedURL = directory.appendingPathComponent("cancelled.qfe")
        try Data(repeating: 0x5c, count: 200_000).write(to: sourceURL)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x29, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)

        do {
            _ = try await service.encryptFile(at: sourceURL, to: encryptedURL) { fraction in
                if fraction > 0 { await session.lock() }
            }
            XCTFail("Locking must revoke an in-flight encryption operation.")
        } catch {
            XCTAssertEqual(error as? VaultError, .authenticationRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: encryptedURL.path))
    }

    func testEncryptingDataWritesTheSameContainerAsEncryptingTheFile() async throws {
        let directory = try XCTUnwrap(directory)
        let sourceURL = directory.appendingPathComponent("source.bin")
        let fromFileURL = directory.appendingPathComponent("from-file.qfe")
        let fromDataURL = directory.appendingPathComponent("from-data.qfe")
        let source = Data((0..<150_000).map { UInt8($0 % 239) })
        try source.write(to: sourceURL)
        let slice = (Data(repeating: 0, count: 10) + source).dropFirst(10)

        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x3c, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        let fileResult = try await service.encryptFile(at: sourceURL, to: fromFileURL, progress: nil)
        let dataResult = try await service.encryptData(slice, to: fromDataURL)

        XCTAssertEqual(dataResult, fileResult)
        let fromFile = try Data(contentsOf: fromFileURL)
        let fromData = try Data(contentsOf: fromDataURL)
        XCTAssertEqual(fromData.count, 48 + source.count + 16 * 3)
        XCTAssertEqual(fromData.count, fromFile.count)
        XCTAssertEqual(fromData.prefix(24), fromFile.prefix(24))
        XCTAssertNotEqual(fromData.subdata(in: 24..<48), fromFile.subdata(in: 24..<48))
        let decrypted = try await service.decryptData(at: fromDataURL, maximumByteCount: 1_000_000)
        XCTAssertEqual(decrypted, source)
    }

    func testEncryptingEmptyDataIsRejectedWithoutOutput() async throws {
        let directory = try XCTUnwrap(directory)
        let outputURL = directory.appendingPathComponent("empty.qfe")
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x3d, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)

        do {
            _ = try await service.encryptData(Data(), to: outputURL)
            XCTFail("Empty data must be rejected.")
        } catch {
            XCTAssertEqual(error as? VaultError, .unsupportedFileType)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testLockRevokesDecryptionAtNextChunkAndRemovesOutput() async throws {
        let directory = try XCTUnwrap(directory)
        let sourceURL = directory.appendingPathComponent("large-source.bin")
        let encryptedURL = directory.appendingPathComponent("large.qfe")
        let outputURL = directory.appendingPathComponent("revoked.bin")
        try Data(repeating: 0x5d, count: 200_000).write(to: sourceURL)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x2a, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        _ = try await service.encryptFile(at: sourceURL, to: encryptedURL, progress: nil)

        do {
            try await service.decryptFile(at: encryptedURL, to: outputURL) { fraction in
                if fraction > 0 { await session.lock() }
            }
            XCTFail("Locking must revoke an in-flight decryption operation.")
        } catch {
            XCTAssertEqual(error as? VaultError, .authenticationRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testLockRevokesEveryConcurrentDecryptAtItsNextChunk() async throws {
        let directory = try XCTUnwrap(directory)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x2b, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        var encryptedURLs: [URL] = []
        for index in 0..<4 {
            let sourceURL = directory.appendingPathComponent("source-\(index).bin")
            let encryptedURL = directory.appendingPathComponent("encrypted-\(index).qfe")
            try Data(repeating: UInt8(index), count: 200_000).write(to: sourceURL)
            _ = try await service.encryptFile(at: sourceURL, to: encryptedURL, progress: nil)
            encryptedURLs.append(encryptedURL)
        }
        let inputURLs = encryptedURLs
        let outputURLs = (0..<4).map { directory.appendingPathComponent("decrypted-\($0).bin") }
        let gate = LockOnFirstChunk(session: session)

        let errors = await withTaskGroup(of: VaultError?.self, returning: [VaultError?].self) { group in
            for (inputURL, outputURL) in zip(inputURLs, outputURLs) {
                group.addTask {
                    do {
                        try await service.decryptFile(at: inputURL, to: outputURL) { _ in
                            await gate.chunkFinished()
                        }
                        return nil
                    } catch {
                        return error as? VaultError
                    }
                }
            }
            var errors: [VaultError?] = []
            for await error in group {
                errors.append(error)
            }
            return errors
        }

        XCTAssertEqual(errors, [VaultError?](repeating: .authenticationRequired, count: 4))
        for outputURL in outputURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    func testInMemoryDecryptReturnsExactBytesAtChunkBoundaries() async throws {
        let directory = try XCTUnwrap(directory)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x2c, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)

        for size in [1, 65_535, 65_536, 65_537, 131_072, 180_000] {
            let plaintext = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ size) })
            let encryptedURL = directory.appendingPathComponent("boundary-\(size).qfe")
            _ = try await service.encryptData(plaintext, to: encryptedURL)

            let decrypted = try await service.decryptData(at: encryptedURL, maximumByteCount: size)

            XCTAssertEqual(decrypted, plaintext, "size \(size)")
        }
    }

    func testInMemoryDecryptKeepsItsErrorsForDamagedOrOversizedContainers() async throws {
        let directory = try XCTUnwrap(directory)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x2d, count: 32))
        let service = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        let encryptedURL = directory.appendingPathComponent("container.qfe")
        _ = try await service.encryptData(Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }), to: encryptedURL)
        let container = try Data(contentsOf: encryptedURL)
        XCTAssertEqual(container.count, 48 + 100_000 + 16 * 2)

        var appended = container
        appended.append(0)
        let truncated = Data(container.dropLast())
        var flippedTag = container
        flippedTag[flippedTag.count - 1] ^= 0x01
        var hugeSize = container
        hugeSize.replaceSubrange(16..<24, with: Data(repeating: 0xFF, count: 8))
        var largerSizeField = Data()
        largerSizeField.appendBigEndian(UInt64(300_000))
        var largerSizeWithMatchingLength = container
        largerSizeWithMatchingLength.replaceSubrange(16..<24, with: largerSizeField)
        largerSizeWithMatchingLength.append(Data(repeating: 0, count: 48 + 300_000 + 16 * 5 - container.count))

        let cases: [(name: String, container: Data, maximumByteCount: Int, error: VaultError)] = [
            ("limit below the size", container, 99_999, .insufficientStorage),
            ("one byte appended", appended, 1_000_000, .corruptedFile),
            ("one byte removed", truncated, 1_000_000, .corruptedFile),
            ("tag byte flipped", flippedTag, 1_000_000, .corruptedFile),
            ("size near UInt64.max", hugeSize, 1_000_000, .corruptedFile),
            ("larger size with a matching length", largerSizeWithMatchingLength, 1_000_000, .corruptedFile)
        ]
        for testCase in cases {
            try testCase.container.write(to: encryptedURL)
            do {
                _ = try await service.decryptData(at: encryptedURL, maximumByteCount: testCase.maximumByteCount)
                XCTFail("\(testCase.name) must not decrypt.")
            } catch {
                XCTAssertEqual(error as? VaultError, testCase.error, testCase.name)
            }
        }
    }
}

/// Locks the session on the first finished chunk of any operation and holds every progress callback until the lock
/// has landed, so each operation's next chunk check runs after the lock.
private actor LockOnFirstChunk {
    private let session: VaultSession
    private var locking: Task<Void, Never>?

    init(session: VaultSession) {
        self.session = session
    }

    func chunkFinished() async {
        let locking: Task<Void, Never>
        if let existing = self.locking {
            locking = existing
        } else {
            let session = session
            locking = Task { await session.lock() }
            self.locking = locking
        }
        await locking.value
    }
}
