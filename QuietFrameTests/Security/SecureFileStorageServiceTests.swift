import Foundation
import XCTest
@testable import QuietFrame

final class SecureFileStorageServiceTests: XCTestCase {
    func testStoredMediaCanBeReadAndTemporaryLeaseCleansUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: cache)
        }

        let sourceURL = cache.appendingPathComponent("source.jpg")
        let source = Data((0..<90_000).map { UInt8($0 % 197) })
        try source.write(to: sourceURL)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x35, count: 32))
        let encryption = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        let storage = try SecureFileStorageService(
            encryption: encryption,
            baseURL: base,
            temporaryBaseURL: cache,
            applyFileProtection: false
        )

        let stored = try await storage.store(plaintextURL: sourceURL, location: .media, progress: nil)
        let decrypted = try await storage.decryptData(
            identifier: stored.identifier,
            location: .media,
            maximumByteCount: 100_000
        )
        XCTAssertEqual(decrypted, source)

        let lease = try await storage.temporaryDecryptedFile(
            identifier: stored.identifier,
            location: .media,
            preferredExtension: "jpg"
        )
        let leasedURL = lease.url
        XCTAssertTrue(FileManager.default.fileExists(atPath: leasedURL.path))
        lease.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasedURL.path))
    }
}
