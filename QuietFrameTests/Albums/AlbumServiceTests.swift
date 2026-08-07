import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class AlbumServiceTests: XCTestCase {
    func testCreateAndRenameAlbum() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)

        let album = try repository.createAlbum(name: "  Family  ")
        XCTAssertEqual(album.name, "Family")

        try repository.renameAlbum(id: album.id, name: "Journeys")
        XCTAssertEqual(album.name, "Journeys")
    }

    func testDeletingAlbumKeepsMediaByDefault() async throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let storage = MockSecureFileStorage()
        let service = AlbumService(
            repository: repository,
            modelContext: container.mainContext,
            storage: storage
        )
        let album = try repository.createAlbum(name: "Private")
        let media = makeMedia(album: album)
        container.mainContext.insert(media)
        try container.mainContext.save()

        try await service.deleteAlbum(id: album.id, mode: .keepMedia)

        XCTAssertNil(media.album)
        XCTAssertNil(media.trashedAt)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultAlbum>()), 0)
        let moveCount = await storage.moveCount
        XCTAssertEqual(moveCount, 0)
    }

    func testExplicitDeleteToTrashMovesEncryptedFile() async throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let storage = MockSecureFileStorage()
        let service = AlbumService(
            repository: repository,
            modelContext: container.mainContext,
            storage: storage
        )
        let album = try repository.createAlbum(name: "Receipts")
        let albumID = album.id
        let media = makeMedia(album: album)
        container.mainContext.insert(media)
        try container.mainContext.save()

        try await service.deleteAlbum(id: albumID, mode: .moveMediaToTrash)

        XCTAssertNotNil(media.trashedAt)
        XCTAssertEqual(media.previousAlbumID, albumID)
        let moveCount = await storage.moveCount
        XCTAssertEqual(moveCount, 1)
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

    private func makeMedia(album: VaultAlbum) -> VaultMedia {
        VaultMedia(
            storageIdentifier: UUID().uuidString,
            contentFingerprint: UUID().uuidString,
            metadata: MediaMetadata(
                mediaType: .photo,
                contentTypeIdentifier: "public.jpeg",
                originalFilename: "sample.jpg",
                originalCreationDate: nil,
                pixelWidth: 100,
                pixelHeight: 100,
                duration: nil,
                byteCount: 1_024
            ),
            album: album
        )
    }
}
