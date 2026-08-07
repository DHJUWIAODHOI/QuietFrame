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
        let media = makeMedia(album: album)
        container.mainContext.insert(album)
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

    private func makeMedia(album: VaultAlbum?) -> VaultMedia {
        VaultMedia(
            storageIdentifier: UUID().uuidString,
            contentFingerprint: UUID().uuidString,
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
