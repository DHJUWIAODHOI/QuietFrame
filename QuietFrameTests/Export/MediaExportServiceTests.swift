import Foundation
import XCTest
@testable import QuietFrame

final class MediaExportServiceTests: XCTestCase {
    func testShareLeaseDeletesTemporaryDecryptedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = cacheRoot.appendingPathComponent("source.jpg")
        let sourceData = Data(repeating: 0xa7, count: 70_000)
        try sourceData.write(to: sourceURL)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x71, count: 32))
        let encryption = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        let storage = try SecureFileStorageService(
            encryption: encryption,
            baseURL: storageRoot,
            temporaryBaseURL: cacheRoot,
            applyFileProtection: false
        )
        let stored = try await storage.store(plaintextURL: sourceURL, location: .media, progress: nil)
        let media = VaultMedia(
            storageIdentifier: stored.identifier,
            contentFingerprint: stored.result.fingerprint,
            metadata: MediaMetadata(
                mediaType: .photo,
                contentTypeIdentifier: "public.jpeg",
                originalFilename: "source.jpg",
                originalCreationDate: nil,
                pixelWidth: 1,
                pixelHeight: 1,
                duration: nil,
                byteCount: Int64(sourceData.count)
            )
        )
        let exporter = MediaExportService(storage: storage)

        let lease = try await exporter.prepareForSharing(media: [media])
        let temporaryURL = try XCTUnwrap(lease.urls.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertEqual(try Data(contentsOf: temporaryURL), sourceData)

        lease.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }
}
