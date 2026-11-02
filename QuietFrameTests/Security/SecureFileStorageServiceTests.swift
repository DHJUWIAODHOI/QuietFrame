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

    func testStoringDataFromMemoryWritesOnlyTheEncryptedFile() async throws {
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

        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x36, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session, chunkByteCount: 65_536),
            baseURL: base,
            temporaryBaseURL: cache,
            applyFileProtection: false
        )
        let thumbnail = Data((0..<20_000).map { UInt8($0 % 181) })

        let stored = try await storage.store(plaintextData: thumbnail, location: .thumbnails)

        XCTAssertEqual(stored.result.plaintextByteCount, Int64(thumbnail.count))
        let thumbnails = try await storage.allIdentifiers(location: .thumbnails)
        XCTAssertEqual(thumbnails, [stored.identifier])
        let decrypted = try await storage.decryptData(
            identifier: stored.identifier,
            location: .thumbnails,
            maximumByteCount: 100_000
        )
        XCTAssertEqual(decrypted, thumbnail)
        for directory in [
            base.appendingPathComponent("QuietFrameVault/staging"),
            cache.appendingPathComponent("QuietFrameTemporary")
        ] {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testReadingDataRunsWhileTheStorageActorIsHeld() async throws {
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
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x38, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session, chunkByteCount: 65_536),
            baseURL: base,
            temporaryBaseURL: cache,
            applyFileProtection: false
        )
        let thumbnail = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let identifier = try await storage.store(plaintextData: thumbnail, location: .thumbnails).identifier

        let held = XCTestExpectation(description: "The storage actor is held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let holder = Task { await storage.holdIsolation(entered: held, release: release) }
        await fulfillment(of: [held], timeout: 10)

        let read = XCTestExpectation(description: "The thumbnail was read while the storage actor was held")
        let reading = Task { () -> Data in
            let data = try await storage.decryptData(identifier: identifier, location: .thumbnails, maximumByteCount: 100_000)
            read.fulfill()
            return data
        }
        await fulfillment(of: [read], timeout: 10)
        release.signal()
        await holder.value

        let decrypted = try await reading.value
        XCTAssertEqual(decrypted, thumbnail)
    }

    func testTemporaryDecryptedFileHoldsTheExactPlaintextAndIsExcludedFromBackup() async throws {
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
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x37, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session, chunkByteCount: 65_536),
            baseURL: base,
            temporaryBaseURL: cache,
            applyFileProtection: false
        )
        let source = Data((0..<180_000).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 5) })
        let stored = try await storage.store(plaintextData: source, location: .media)

        let lease = try await storage.temporaryDecryptedFile(
            identifier: stored.identifier,
            location: .media,
            preferredExtension: "JPG"
        )
        let leasedURL = lease.url
        let name = leasedURL.deletingPathExtension().lastPathComponent
        let backupValues = try URL(fileURLWithPath: leasedURL.path).resourceValues(forKeys: [.isExcludedFromBackupKey])

        XCTAssertEqual(try Data(contentsOf: leasedURL), source)
        XCTAssertEqual(backupValues.isExcludedFromBackup, true)
        XCTAssertEqual(leasedURL.deletingLastPathComponent().path, cache.appendingPathComponent("QuietFrameTemporary").path)
        XCTAssertEqual(leasedURL.pathExtension, "jpg")
        XCTAssertNotNil(UUID(uuidString: name))
        XCTAssertEqual(name, name.lowercased())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("QuietFrameVault/staging").path),
            []
        )
        lease.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasedURL.path))
    }
}

private extension SecureFileStorageService {
    /// Occupies the actor until `release` is signalled, as a long listing or cleanup would.
    func holdIsolation(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 30)
    }
}
