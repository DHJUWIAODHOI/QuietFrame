import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class StorageReconciliationServiceTests: XCTestCase {
    func testRepairsInterruptedMoveAndDeletesUnreferencedFiles() async throws {
        let container = try makeContainer()
        let active = makeMedia()
        container.mainContext.insert(active)
        try container.mainContext.save()
        let orphan = UUID().uuidString.lowercased()
        let orphanThumbnail = UUID().uuidString.lowercased()
        let storage = MockSecureFileStorage(identifiers: [
            .media: [orphan],
            .trash: [active.storageIdentifier],
            .thumbnails: [orphanThumbnail]
        ])
        let service = StorageReconciliationService(
            modelContext: container.mainContext,
            storage: storage
        )

        let result = try await service.reconcile()

        XCTAssertEqual(result.repairedLocations, 1)
        XCTAssertEqual(result.deletedOrphans, 2)
        XCTAssertEqual(result.missingFiles, 0)
        let moveCount = await storage.moveCount
        let deleteCount = await storage.deleteCount
        XCTAssertEqual(moveCount, 1)
        XCTAssertEqual(deleteCount, 2)
    }

    func testReconcilingInAFreshContextKeepsEveryAttributeReadable() async throws {
        let container = try makeContainer()
        let album = VaultAlbum(name: "Holiday")
        container.mainContext.insert(album)
        let thumbnailID = UUID().uuidString.lowercased()
        let active = VaultMedia(
            storageIdentifier: UUID().uuidString.lowercased(),
            contentFingerprint: UUID().uuidString,
            thumbnailIdentifier: thumbnailID,
            metadata: MediaMetadata(
                mediaType: .video,
                contentTypeIdentifier: "com.apple.quicktime-movie",
                originalFilename: "IMG_0042.MOV",
                originalCreationDate: Date(timeIntervalSince1970: 1_600_000_000),
                pixelWidth: 1_920,
                pixelHeight: 1_080,
                duration: 12,
                byteCount: 4_096
            ),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isFavorite: true,
            tags: ["beach"],
            album: album
        )
        let trashed = makeMedia()
        trashed.trashedAt = Date(timeIntervalSince1970: 1_750_000_000)
        container.mainContext.insert(active)
        container.mainContext.insert(trashed)
        try container.mainContext.save()
        let storage = MockSecureFileStorage(identifiers: [
            .media: [active.storageIdentifier],
            .trash: [trashed.storageIdentifier],
            .thumbnails: [thumbnailID]
        ])
        let context = ModelContext(container)

        let result = try await StorageReconciliationService(modelContext: context, storage: storage).reconcile()

        XCTAssertEqual(result, ReconciliationResult(repairedLocations: 0, deletedOrphans: 0, missingFiles: 0))
        let reloaded = try context.fetch(FetchDescriptor<VaultMedia>())
        let reloadedActive = try XCTUnwrap(reloaded.first { $0.storageIdentifier == active.storageIdentifier })
        XCTAssertEqual(reloadedActive.originalFilename, "IMG_0042.MOV")
        XCTAssertEqual(reloadedActive.pixelWidth, 1_920)
        XCTAssertEqual(reloadedActive.duration, 12)
        XCTAssertTrue(reloadedActive.isFavorite)
        XCTAssertEqual(reloadedActive.tags, ["beach"])
        XCTAssertEqual(reloadedActive.album?.name, "Holiday")
        XCTAssertEqual(reloaded.filter(\.isTrashed).count, 1)
    }

    func testReportsMissingReferencedFileWithoutDeletingMetadata() async throws {
        let container = try makeContainer()
        let active = makeMedia()
        container.mainContext.insert(active)
        try container.mainContext.save()
        let service = StorageReconciliationService(
            modelContext: container.mainContext,
            storage: MockSecureFileStorage()
        )

        let result = try await service.reconcile()

        XCTAssertEqual(result.missingFiles, 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 1)
    }

    func testReconciliationWaitsForTrashMetadataCommit() async throws {
        let container = try makeContainer()
        let media = makeMedia()
        container.mainContext.insert(media)
        try container.mainContext.save()
        let storage = MockSecureFileStorage(identifiers: [.media: [media.storageIdentifier]])
        let operationGate = VaultOperationGate()
        let trash = TrashService(
            modelContext: container.mainContext,
            storage: storage,
            operationGate: operationGate
        )
        let reconciliation = StorageReconciliationService(
            modelContext: container.mainContext,
            storage: storage,
            operationGate: operationGate
        )
        await storage.pauseNextMove()

        let trashTask = Task { try await trash.moveToTrash(ids: [media.id]) }
        await storage.waitForPausedMove()
        let reconciliationTask = Task { try await reconciliation.reconcile() }
        var waitingCount = 0
        for _ in 0..<1_000 {
            waitingCount = await operationGate.waitingCount
            if waitingCount > 0 { break }
            await Task.yield()
        }

        XCTAssertEqual(waitingCount, 1)
        let enumerationCountWhileMoveIsPaused = await storage.allIdentifiersCount
        XCTAssertEqual(enumerationCountWhileMoveIsPaused, 0)

        await storage.resumePausedMove()
        try await trashTask.value
        let result = try await reconciliationTask.value
        let identifiers = await storage.identifiers
        let mediaFiles = identifiers[.media] ?? []
        let trashFiles = identifiers[.trash] ?? []

        XCTAssertNotNil(media.trashedAt)
        XCTAssertFalse(mediaFiles.contains(media.storageIdentifier))
        XCTAssertTrue(trashFiles.contains(media.storageIdentifier))
        XCTAssertEqual(result, ReconciliationResult(repairedLocations: 0, deletedOrphans: 0, missingFiles: 0))
    }

    func testEveryPageSizeReconcilesLikeOneFetch() async throws {
        let container = try makeContainer()
        let library = try insertMixedLibrary(itemCount: 44, in: container)
        XCTAssertGreaterThan(library.result.repairedLocations, 0)
        XCTAssertGreaterThan(library.result.missingFiles, 0)

        for pageSize in [1, 7, 8, 44, 500, 10_000] {
            XCTAssertFalse(container.mainContext.hasChanges)
            let storage = MockSecureFileStorage(identifiers: library.files)
            let service = StorageReconciliationService(
                modelContext: container.mainContext,
                storage: storage,
                pageSize: pageSize
            )

            let result = try await service.reconcile()

            let files = await storedFiles(in: storage)
            let moveCount = await storage.moveCount
            let deleteCount = await storage.deleteCount
            XCTAssertEqual(result, library.result, "Page size \(pageSize)")
            XCTAssertEqual(files, library.reconciledFiles, "Page size \(pageSize)")
            XCTAssertEqual(moveCount, library.result.repairedLocations, "Page size \(pageSize)")
            XCTAssertEqual(deleteCount, library.result.deletedOrphans, "Page size \(pageSize)")
        }
    }

    func testCancellingWhileReadingReferencesTouchesNoFile() async throws {
        let container = try makeContainer()
        let library = try insertMixedLibrary(itemCount: 300, in: container)
        let storage = MockSecureFileStorage(identifiers: library.files)
        let operationGate = VaultOperationGate()
        let service = StorageReconciliationService(
            modelContext: container.mainContext,
            storage: storage,
            operationGate: operationGate,
            pageSize: 1
        )
        XCTAssertFalse(container.mainContext.hasChanges)

        let reconciliation = Task { try await service.reconcile() }
        let nextOperation = Task { try await operationGate.withLock {} }
        var waitingCount = 0
        for _ in 0..<1_000 {
            waitingCount = await operationGate.waitingCount
            if waitingCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(waitingCount, 1)
        reconciliation.cancel()

        do {
            _ = try await reconciliation.value
            XCTFail("A cancelled reconciliation should stop before it touches any file.")
        } catch is CancellationError {
        }
        try await nextOperation.value
        let files = await storedFiles(in: storage)
        let moveCount = await storage.moveCount
        let deleteCount = await storage.deleteCount
        let listingCount = await storage.allIdentifiersCount
        XCTAssertEqual(files, library.files)
        XCTAssertEqual(moveCount, 0)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(listingCount, 0)
    }

    func testUnsavedChangesAreReadAsOneFetchReadsThem() async throws {
        let container = try makeContainer()
        let library = try insertMixedLibrary(itemCount: 16, in: container)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let unsaved = makeMedia()
        context.insert(unsaved)
        XCTAssertTrue(context.hasChanges)
        let isReferencedByOneFetch = try context.fetch(FetchDescriptor<VaultMedia>())
            .contains { $0.storageIdentifier == unsaved.storageIdentifier }
        var files = library.files
        files[.media, default: []].insert(unsaved.storageIdentifier)
        let storage = MockSecureFileStorage(identifiers: files)

        let result = try await StorageReconciliationService(
            modelContext: context,
            storage: storage,
            pageSize: 1
        ).reconcile()

        let reconciledFiles = await storedFiles(in: storage)
        let mediaFiles = reconciledFiles[.media] ?? []
        XCTAssertEqual(mediaFiles.contains(unsaved.storageIdentifier), isReferencedByOneFetch)
        XCTAssertEqual(
            result,
            ReconciliationResult(
                repairedLocations: library.result.repairedLocations,
                deletedOrphans: library.result.deletedOrphans + (isReferencedByOneFetch ? 0 : 1),
                missingFiles: library.result.missingFiles
            )
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeMedia() -> VaultMedia {
        VaultMedia(
            storageIdentifier: UUID().uuidString.lowercased(),
            contentFingerprint: UUID().uuidString,
            metadata: MediaMetadata(
                mediaType: .photo,
                contentTypeIdentifier: "public.jpeg",
                originalFilename: nil,
                originalCreationDate: nil,
                pixelWidth: 10,
                pixelHeight: 10,
                duration: nil,
                byteCount: 100
            )
        )
    }

    private struct MixedLibrary {
        let files: [EncryptedAssetLocation: Set<String>]
        let reconciledFiles: [EncryptedAssetLocation: Set<String>]
        let result: ReconciliationResult
    }

    /// Cycles through every state reconciliation handles: active and trashed items whose file is in their folder, left
    /// in the other folder by an interrupted move, missing, or in both folders, every third one with a thumbnail, plus
    /// three unreferenced files in each folder. Returns the files before and after, and the result, by today's rules.
    private func insertMixedLibrary(itemCount: Int, in container: ModelContainer) throws -> MixedLibrary {
        var files: [EncryptedAssetLocation: Set<String>] = [.media: [], .trash: [], .thumbnails: []]
        var reconciledFiles = files
        var repaired = 0
        var missing = 0
        for index in 0..<itemCount {
            let media = makeMedia()
            let identifier = media.storageIdentifier
            let isTrashed = index % 8 >= 4
            if isTrashed {
                media.trashedAt = Date(timeIntervalSince1970: 1_750_000_000)
            }
            if index % 3 == 0 {
                let thumbnailIdentifier = UUID().uuidString.lowercased()
                media.thumbnailIdentifier = thumbnailIdentifier
                files[.thumbnails, default: []].insert(thumbnailIdentifier)
                reconciledFiles[.thumbnails, default: []].insert(thumbnailIdentifier)
            }
            let home: EncryptedAssetLocation = isTrashed ? .trash : .media
            let away: EncryptedAssetLocation = isTrashed ? .media : .trash
            switch index % 4 {
            case 0:
                files[home, default: []].insert(identifier)
                reconciledFiles[home, default: []].insert(identifier)
            case 1:
                files[away, default: []].insert(identifier)
                reconciledFiles[home, default: []].insert(identifier)
                repaired += 1
            case 2:
                missing += 1
            default:
                files[home, default: []].insert(identifier)
                files[away, default: []].insert(identifier)
                reconciledFiles[home, default: []].insert(identifier)
                reconciledFiles[away, default: []].insert(identifier)
            }
            container.mainContext.insert(media)
        }
        try container.mainContext.save()
        let orphansPerFolder = 3
        for location in [EncryptedAssetLocation.media, .trash, .thumbnails] {
            for _ in 0..<orphansPerFolder {
                files[location, default: []].insert(UUID().uuidString.lowercased())
            }
        }
        return MixedLibrary(
            files: files,
            reconciledFiles: reconciledFiles,
            result: ReconciliationResult(
                repairedLocations: repaired,
                deletedOrphans: orphansPerFolder * 3,
                missingFiles: missing
            )
        )
    }

    private func storedFiles(in storage: MockSecureFileStorage) async -> [EncryptedAssetLocation: Set<String>] {
        let identifiers = await storage.identifiers
        return [
            .media: identifiers[.media] ?? [],
            .trash: identifiers[.trash] ?? [],
            .thumbnails: identifiers[.thumbnails] ?? []
        ]
    }
}
