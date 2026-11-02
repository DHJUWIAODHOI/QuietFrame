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

    func testFileByteCountsListOnlyRegularVaultFiles() async throws {
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let small = try vault.place(in: .media, byteCount: 10)
        let large = try vault.place(in: .media, byteCount: 4_000)
        let empty = try vault.place(in: .media, byteCount: 0)
        let uppercase = try vault.place(UUID().uuidString.uppercased(), in: .media, byteCount: 77)
        try FileManager.default.createDirectory(
            at: vault.url(of: UUID().uuidString.lowercased(), in: .media),
            withIntermediateDirectories: false
        )
        try vault.place(".\(UUID().uuidString.lowercased())", in: .media)
        try vault.place("not-a-uuid", in: .media)
        let textFile = vault.directory(for: .media).appendingPathComponent("\(UUID().uuidString.lowercased()).txt")
        try Data(repeating: 0x42, count: 9).write(to: textFile)
        try vault.place(in: .trash, byteCount: 3)
        let storage: any SecureFileStoring = vault.storage

        let sizes = try await storage.fileByteCounts(location: .media)

        XCTAssertEqual(sizes, [small: 10, large: 4_000, empty: 0, uppercase: 77])
        for (identifier, size) in sizes {
            let measured = try await storage.fileByteCount(identifier: identifier, location: .media)
            XCTAssertEqual(measured, size, identifier)
        }
    }

    func testBatchMoveStopsAtTheFirstFailure() async throws {
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let first = try vault.place(in: .media)
        let blocked = try vault.place(in: .media)
        let last = try vault.place(in: .media)
        try vault.place(blocked, in: .trash)

        let result = await vault.storage.move(identifiers: [first, blocked, last], from: .media, to: .trash)

        XCTAssertEqual(result.moved, [first])
        XCTAssertEqual(result.failure as? VaultError, .fileOperationFailed)
        XCTAssertTrue(vault.contains(first, in: .trash))
        XCTAssertFalse(vault.contains(first, in: .media))
        XCTAssertTrue(vault.contains(blocked, in: .media))
        XCTAssertTrue(vault.contains(last, in: .media))
        XCTAssertFalse(vault.contains(last, in: .trash))
    }

    func testBatchMoveReappliesBackupExclusion() async throws {
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        var identifiers: [String] = []
        for _ in 0..<3 {
            let identifier = try vault.place(in: .media)
            var url = vault.url(of: identifier, in: .media)
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try url.setResourceValues(values)
            identifiers.append(identifier)
        }

        let result = await vault.storage.move(identifiers: identifiers, from: .media, to: .trash)

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.moved, identifiers)
        for identifier in identifiers {
            let values = try vault.url(of: identifier, in: .trash).resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }
    }

    func testBatchDeleteSkipsTheRestOfAFailedItem() async throws {
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let keptThumbnail = try vault.place(in: .thumbnails)
        let original = try vault.place(in: .trash)
        let thumbnail = try vault.place(in: .thumbnails)

        let failedItemCount = await vault.storage.deleteFiles(ofItems: [
            [
                EncryptedFileReference(identifier: "not-a-uuid", location: .trash),
                EncryptedFileReference(identifier: keptThumbnail, location: .thumbnails)
            ],
            [
                EncryptedFileReference(identifier: original, location: .trash),
                EncryptedFileReference(identifier: thumbnail, location: .thumbnails)
            ]
        ])

        XCTAssertEqual(failedItemCount, 1)
        XCTAssertTrue(vault.contains(keptThumbnail, in: .thumbnails))
        XCTAssertFalse(vault.contains(original, in: .trash))
        XCTAssertFalse(vault.contains(thumbnail, in: .thumbnails))
    }

    /// Test doubles get the protocol's batch defaults; the real storage runs its own loops. Both must agree.
    func testProtocolDefaultsMatchTheBatchImplementation() async throws {
        let batched = try TemporaryVaultStorage()
        let defaulted = try TemporaryVaultStorage()
        defer {
            batched.remove()
            defaulted.remove()
        }
        let moved = UUID().uuidString.lowercased()
        let blocked = UUID().uuidString.lowercased()
        let notReached = UUID().uuidString.lowercased()
        let original = UUID().uuidString.lowercased()
        let thumbnail = UUID().uuidString.lowercased()
        let keptThumbnail = UUID().uuidString.lowercased()
        for vault in [batched, defaulted] {
            try vault.place(moved, in: .media)
            try vault.place(blocked, in: .media)
            try vault.place(blocked, in: .trash)
            try vault.place(notReached, in: .media)
            try vault.place(original, in: .trash)
            try vault.place(thumbnail, in: .thumbnails)
            try vault.place(keptThumbnail, in: .thumbnails)
        }
        let identifiers = [moved, blocked, notReached]
        let items = [
            [
                EncryptedFileReference(identifier: "not-a-uuid", location: .trash),
                EncryptedFileReference(identifier: keptThumbnail, location: .thumbnails)
            ],
            [EncryptedFileReference(identifier: UUID().uuidString.lowercased(), location: .trash)],
            [
                EncryptedFileReference(identifier: original, location: .trash),
                EncryptedFileReference(identifier: thumbnail, location: .thumbnails)
            ]
        ]
        let batchedStorage: any SecureFileStoring = batched.storage
        let defaultedStorage: any SecureFileStoring = SingleFileStorage(wrapping: defaulted.storage)

        let batchedMove = await batchedStorage.move(identifiers: identifiers, from: .media, to: .trash)
        let defaultedMove = await defaultedStorage.move(identifiers: identifiers, from: .media, to: .trash)
        let batchedFailures = await batchedStorage.deleteFiles(ofItems: items)
        let defaultedFailures = await defaultedStorage.deleteFiles(ofItems: items)
        let defaultedSizes = try await defaultedStorage.fileByteCounts(location: .media)

        XCTAssertEqual(batchedMove.moved, [moved])
        XCTAssertEqual(defaultedMove.moved, batchedMove.moved)
        XCTAssertEqual(batchedMove.failure as? VaultError, .fileOperationFailed)
        XCTAssertEqual(defaultedMove.failure as? VaultError, .fileOperationFailed)
        XCTAssertEqual(batchedFailures, 1)
        XCTAssertEqual(defaultedFailures, batchedFailures)
        XCTAssertTrue(defaultedSizes.isEmpty)
        for location in [EncryptedAssetLocation.media, .trash, .thumbnails] {
            let batchedNames = try batched.fileNames(in: location)
            let defaultedNames = try defaulted.fileNames(in: location)
            XCTAssertEqual(defaultedNames, batchedNames, location.rawValue)
        }
    }
}

/// Implements only the single-file calls, so the protocol's batch and listing defaults run over real storage.
private actor SingleFileStorage: SecureFileStoring {
    private let storage: any SecureFileStoring

    init(wrapping storage: any SecureFileStoring) {
        self.storage = storage
    }

    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile {
        try await storage.store(plaintextURL: plaintextURL, location: location, progress: progress)
    }

    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile {
        try await storage.store(plaintextData: plaintextData, location: location)
    }

    func decryptData(
        identifier: String,
        location: EncryptedAssetLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        try await storage.decryptData(identifier: identifier, location: location, maximumByteCount: maximumByteCount)
    }

    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease {
        try await storage.temporaryDecryptedFile(
            identifier: identifier,
            location: location,
            preferredExtension: preferredExtension
        )
    }

    func move(identifier: String, from: EncryptedAssetLocation, to: EncryptedAssetLocation) async throws {
        try await storage.move(identifier: identifier, from: from, to: to)
    }

    func delete(identifier: String, location: EncryptedAssetLocation) async throws {
        try await storage.delete(identifier: identifier, location: location)
    }

    func cleanupTemporaryFiles() async {
        await storage.cleanupTemporaryFiles()
    }

    func removeAllEncryptedData() async throws {
        try await storage.removeAllEncryptedData()
    }

    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64 {
        try await storage.fileByteCount(identifier: identifier, location: location)
    }

    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String> {
        try await storage.allIdentifiers(location: location)
    }

    func openEncryptedReader(identifier: String, location: EncryptedAssetLocation) async throws -> EncryptedFileReader {
        try await storage.openEncryptedReader(identifier: identifier, location: location)
    }
}

private extension SecureFileStorageService {
    /// Occupies the actor until `release` is signalled, as a long listing or cleanup would.
    func holdIsolation(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 30)
    }
}
