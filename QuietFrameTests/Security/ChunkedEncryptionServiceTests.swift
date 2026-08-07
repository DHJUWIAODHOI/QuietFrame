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
}
