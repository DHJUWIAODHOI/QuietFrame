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
}
