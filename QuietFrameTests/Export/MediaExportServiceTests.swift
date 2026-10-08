import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class MediaExportServiceTests: XCTestCase {
    private struct ExportEnvironment {
        let root: URL
        let cacheRoot: URL
        let container: ModelContainer
        let repository: VaultRepository
        let storage: SecureFileStorageService
        let exporter: MediaExportService
    }

    func testShareLeaseDeletesTemporaryDecryptedFile() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sourceData = Data(repeating: 0xa7, count: 70_000)
        let mediaID = try await storeMedia(sourceData, in: environment)

        let lease = try await environment.exporter.prepareForSharing(mediaIDs: [mediaID])
        let temporaryURL = try XCTUnwrap(lease.urls.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertEqual(try Data(contentsOf: temporaryURL), sourceData)

        lease.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testShareResolvesLocationAfterQueuedTrashMove() async throws {
        let operationGate = VaultOperationGate()
        let environment = try await makeEnvironment(operationGate: operationGate)
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sourceData = Data((0..<90_000).map { UInt8($0 % 251) })
        let mediaID = try await storeMedia(sourceData, in: environment)
        let blocker = GateBlocker()
        let gateHolder = Task { try await operationGate.withLock { await blocker.block() } }
        try await waitUntil { await blocker.hasEntered }

        let export = Task { try await environment.exporter.prepareForSharing(mediaIDs: [mediaID]) }
        try await waitUntil { await operationGate.waitingCount == 1 }

        // While the export waits for the gate, the item moves to Trash the way TrashService does.
        let media = try fetchMedia(id: mediaID, in: environment)
        try await environment.storage.move(identifier: media.storageIdentifier, from: .media, to: .trash)
        media.trashedAt = Date()
        try environment.container.mainContext.save()
        await blocker.open()
        try await gateHolder.value

        let lease = try await export.value
        defer { lease.cleanup() }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(lease.urls.first)), sourceData)
    }

    func testShareRejectsMissingMedia() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let mediaID = try await storeMedia(Data(repeating: 0x3c, count: 4_096), in: environment)

        do {
            _ = try await environment.exporter.prepareForSharing(mediaIDs: [mediaID, UUID()])
            XCTFail("Exporting an item that no longer exists must fail.")
        } catch {
            XCTAssertEqual(
                error as? VaultError,
                .invalidInput("One or more selected items are no longer available.")
            )
        }
        XCTAssertEqual(try temporaryFiles(in: environment), [])
    }

    func testSharePartialFailureCleansUpDecryptedFiles() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let firstID = try await storeMedia(Data(repeating: 0x11, count: 8_192), in: environment)
        let secondID = try await storeMedia(Data(repeating: 0x22, count: 8_192), in: environment)
        let second = try fetchMedia(id: secondID, in: environment)
        try await environment.storage.delete(identifier: second.storageIdentifier, location: .media)

        do {
            _ = try await environment.exporter.prepareForSharing(mediaIDs: [firstID, secondID])
            XCTFail("Exporting an item whose encrypted file is missing must fail.")
        } catch {
            XCTAssertEqual(error as? VaultError, .corruptedFile)
        }
        XCTAssertEqual(try temporaryFiles(in: environment), [])
    }

    func testShareRejectsEmptySelection() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }

        do {
            _ = try await environment.exporter.prepareForSharing(mediaIDs: [])
            XCTFail("An empty export selection must fail.")
        } catch {
            XCTAssertEqual(error as? VaultError, .invalidInput("Select at least one item to export."))
        }
    }

    private func makeEnvironment(
        operationGate: VaultOperationGate = VaultOperationGate()
    ) async throws -> ExportEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let schema = Schema([
            VaultMedia.self,
            VaultAlbum.self,
            AppSettings.self,
            ImportRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = VaultRepository(modelContext: container.mainContext)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x71, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session, chunkByteCount: 65_536),
            baseURL: storageRoot,
            temporaryBaseURL: cacheRoot,
            applyFileProtection: false
        )
        return ExportEnvironment(
            root: root,
            cacheRoot: cacheRoot,
            container: container,
            repository: repository,
            storage: storage,
            exporter: MediaExportService(storage: storage, repository: repository, operationGate: operationGate)
        )
    }

    private func storeMedia(_ data: Data, in environment: ExportEnvironment) async throws -> UUID {
        let sourceURL = environment.root.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: sourceURL)
        let stored = try await environment.storage.store(plaintextURL: sourceURL, location: .media, progress: nil)
        return try environment.repository.insertImportedMedia(
            storageIdentifier: stored.identifier,
            thumbnailIdentifier: nil,
            fingerprint: stored.result.fingerprint,
            metadata: MediaMetadata(
                mediaType: .photo,
                contentTypeIdentifier: "public.jpeg",
                originalFilename: "source.jpg",
                originalCreationDate: nil,
                pixelWidth: 1,
                pixelHeight: 1,
                duration: nil,
                byteCount: Int64(data.count)
            ),
            albumID: nil
        )
    }

    private func fetchMedia(id: UUID, in environment: ExportEnvironment) throws -> VaultMedia {
        var descriptor = FetchDescriptor<VaultMedia>(
            predicate: #Predicate { media in media.id == id }
        )
        descriptor.fetchLimit = 1
        return try XCTUnwrap(environment.container.mainContext.fetch(descriptor).first)
    }

    private func temporaryFiles(in environment: ExportEnvironment) throws -> [String] {
        let directory = environment.cacheRoot.appendingPathComponent("QuietFrameTemporary", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the export to reach the expected state.")
    }
}

private actor GateBlocker {
    private(set) var hasEntered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func block() async {
        hasEntered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
