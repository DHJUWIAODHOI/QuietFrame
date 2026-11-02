import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class TrashServiceTests: XCTestCase {
    func testMoveToTrashAndRestoreReturnsOriginalAlbum() async throws {
        let container = try makeContainer()
        let storage = MockSecureFileStorage()
        let service = TrashService(modelContext: container.mainContext, storage: storage)
        let album = VaultAlbum(name: "Private")
        container.mainContext.insert(album)
        try container.mainContext.save()
        let media = makeMedia(album: album)
        container.mainContext.insert(media)
        try container.mainContext.save()

        try await service.moveToTrash(ids: [media.id])
        XCTAssertNotNil(media.trashedAt)
        XCTAssertNil(media.album)

        try await service.restore(ids: [media.id])
        XCTAssertNil(media.trashedAt)
        XCTAssertEqual(media.album?.id, album.id)
        let moveCount = await storage.moveCount
        XCTAssertEqual(moveCount, 2)
    }

    func testPermanentDeleteRemovesMetadataAndEncryptedFiles() async throws {
        let container = try makeContainer()
        let storage = MockSecureFileStorage()
        let service = TrashService(modelContext: container.mainContext, storage: storage)
        let media = makeMedia(album: nil)
        container.mainContext.insert(media)
        try container.mainContext.save()
        let mediaID = media.id

        try await service.moveToTrash(ids: [mediaID])
        try await service.permanentlyDelete(ids: [mediaID])

        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 0)
        let deleteCount = await storage.deleteCount
        XCTAssertEqual(deleteCount, 1)
    }

    func testExpiredTrashIsPurgedUsingSettings() async throws {
        let container = try makeContainer()
        let storage = MockSecureFileStorage()
        let service = TrashService(modelContext: container.mainContext, storage: storage)
        let settings = AppSettings(trashRetentionPeriod: .sevenDays)
        let media = makeMedia(album: nil)
        media.trashedAt = Calendar.current.date(byAdding: .day, value: -8, to: Date())
        container.mainContext.insert(settings)
        container.mainContext.insert(media)
        try container.mainContext.save()

        let deletedCount = try await service.purgeExpiredItems()

        XCTAssertEqual(deletedCount, 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 0)
    }

    func testFailedMoveToTrashPutsMovedFilesBack() async throws {
        let container = try makeContainer()
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let service = TrashService(modelContext: container.mainContext, storage: vault.storage)
        let album = VaultAlbum(name: "Private")
        container.mainContext.insert(album)
        try container.mainContext.save()
        var media: [VaultMedia] = []
        for _ in 0..<3 {
            let identifier = try vault.place(in: .media)
            let item = makeMedia(album: album, storageIdentifier: identifier)
            container.mainContext.insert(item)
            media.append(item)
        }
        try container.mainContext.save()
        let blocked = media[2].storageIdentifier
        try vault.place(blocked, in: .trash)

        do {
            try await service.moveToTrash(ids: Set(media.map(\.id)))
            XCTFail("The move into a taken name should fail.")
        } catch {
            XCTAssertEqual(error as? VaultError, .fileOperationFailed)
        }

        for item in media {
            XCTAssertTrue(vault.contains(item.storageIdentifier, in: .media))
            XCTAssertNil(item.trashedAt)
            XCTAssertEqual(item.album?.id, album.id)
        }
        XCTAssertEqual(try vault.fileNames(in: .trash), ["\(blocked).qfe"])
    }

    func testFailedRestorePutsRestoredFilesBackInTrash() async throws {
        let container = try makeContainer()
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let service = TrashService(modelContext: container.mainContext, storage: vault.storage)
        var media: [VaultMedia] = []
        for _ in 0..<3 {
            let identifier = try vault.place(in: .trash)
            let item = makeMedia(album: nil, storageIdentifier: identifier)
            item.trashedAt = Date()
            container.mainContext.insert(item)
            media.append(item)
        }
        try container.mainContext.save()
        let blocked = media[0].storageIdentifier
        try vault.place(blocked, in: .media)

        do {
            try await service.restore(ids: Set(media.map(\.id)))
            XCTFail("The restore into a taken name should fail.")
        } catch {
            XCTAssertEqual(error as? VaultError, .fileOperationFailed)
        }

        for item in media {
            XCTAssertTrue(vault.contains(item.storageIdentifier, in: .trash))
            XCTAssertNotNil(item.trashedAt)
        }
        XCTAssertEqual(try vault.fileNames(in: .media), ["\(blocked).qfe"])
    }

    func testPermanentDeleteKeepsTheThumbnailWhenItsOriginalCannotBeDeleted() async throws {
        let container = try makeContainer()
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let service = TrashService(modelContext: container.mainContext, storage: vault.storage)
        let undeletableThumbnail = try vault.place(in: .thumbnails)
        let original = try vault.place(in: .trash)
        let thumbnail = try vault.place(in: .thumbnails)
        let undeletable = makeMedia(
            album: nil,
            storageIdentifier: "not-a-uuid",
            thumbnailIdentifier: undeletableThumbnail
        )
        let deletable = makeMedia(album: nil, storageIdentifier: original, thumbnailIdentifier: thumbnail)
        for item in [undeletable, deletable] {
            item.trashedAt = Date()
            container.mainContext.insert(item)
        }
        try container.mainContext.save()
        let ids: Set<UUID> = [undeletable.id, deletable.id]

        do {
            try await service.permanentlyDelete(ids: ids)
            XCTFail("An original that cannot be deleted should fail the delete.")
        } catch {
            XCTAssertEqual(error as? VaultError, .fileOperationFailed)
        }

        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 0)
        XCTAssertFalse(vault.contains(original, in: .trash))
        XCTAssertFalse(vault.contains(thumbnail, in: .thumbnails))
        XCTAssertTrue(vault.contains(undeletableThumbnail, in: .thumbnails))
    }

    func testBulkTrashOperationsMakeOneStorageCall() async throws {
        let container = try makeContainer()
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let storage = CountingSecureFileStorage(wrapping: vault.storage)
        let service = TrashService(modelContext: container.mainContext, storage: storage)
        var media: [VaultMedia] = []
        for _ in 0..<3 {
            let identifier = try vault.place(in: .media)
            let thumbnail = try vault.place(in: .thumbnails)
            let item = makeMedia(album: nil, storageIdentifier: identifier, thumbnailIdentifier: thumbnail)
            container.mainContext.insert(item)
            media.append(item)
        }
        try container.mainContext.save()
        let ids = Set(media.map(\.id))

        try await service.moveToTrash(ids: ids)
        let movesToTrash = await storage.batchMoveCalls
        try await service.restore(ids: ids)
        let movesIncludingRestore = await storage.batchMoveCalls
        try await service.moveToTrash(ids: ids)
        try await service.permanentlyDelete(ids: ids)

        XCTAssertEqual(movesToTrash, 1)
        XCTAssertEqual(movesIncludingRestore, 2)
        let batchDeleteCalls = await storage.batchDeleteCalls
        let singleMoveCalls = await storage.moveCalls
        let singleDeleteCalls = await storage.deleteCalls
        XCTAssertEqual(batchDeleteCalls, 1)
        XCTAssertEqual(singleMoveCalls, 0)
        XCTAssertEqual(singleDeleteCalls, 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 0)
        for location in [EncryptedAssetLocation.media, .trash, .thumbnails] {
            XCTAssertEqual(try vault.fileNames(in: location), [], location.rawValue)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            VaultMedia.self,
            VaultAlbum.self,
            AppSettings.self,
            ImportRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeMedia(
        album: VaultAlbum?,
        storageIdentifier: String = UUID().uuidString,
        thumbnailIdentifier: String? = nil
    ) -> VaultMedia {
        VaultMedia(
            storageIdentifier: storageIdentifier,
            contentFingerprint: UUID().uuidString,
            thumbnailIdentifier: thumbnailIdentifier,
            metadata: MediaMetadata(
                mediaType: .photo,
                contentTypeIdentifier: "public.jpeg",
                originalFilename: "private.jpg",
                originalCreationDate: nil,
                pixelWidth: 100,
                pixelHeight: 80,
                duration: nil,
                byteCount: 2_048
            ),
            album: album
        )
    }
}
