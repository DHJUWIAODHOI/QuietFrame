import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class AlbumsScreenTests: XCTestCase {
    func testAlbumsFollowTheChosenSort() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let tenth = VaultAlbum(name: "Album 10", createdAt: Date(timeIntervalSince1970: 100), position: 0)
        let second = VaultAlbum(name: "album 2", createdAt: Date(timeIntervalSince1970: 300), position: 1)
        let zoo = VaultAlbum(name: "Zoo", createdAt: Date(timeIntervalSince1970: 200), position: 2)
        tenth.modifiedAt = Date(timeIntervalSince1970: 900)
        second.modifiedAt = Date(timeIntervalSince1970: 400)
        zoo.modifiedAt = Date(timeIntervalSince1970: 600)
        let albums = [tenth, second, zoo]
        albums.forEach { context.insert($0) }
        try context.save()

        XCTAssertEqual(AlbumsScreen.sortedAlbums(albums, by: .manual).map(\.name), ["Album 10", "album 2", "Zoo"])
        XCTAssertEqual(AlbumsScreen.sortedAlbums(albums, by: .name).map(\.name), ["album 2", "Album 10", "Zoo"])
        XCTAssertEqual(
            AlbumsScreen.sortedAlbums(albums, by: .creationDate).map(\.name),
            ["album 2", "Zoo", "Album 10"]
        )
        XCTAssertEqual(
            AlbumsScreen.sortedAlbums(albums, by: .modifiedDate).map(\.name),
            ["Album 10", "Zoo", "album 2"]
        )
    }

    func testAnAlbumShowsItsChosenCoverWhileItIsActive() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = VaultAlbum(name: "Trip")
        context.insert(album)
        let media = try insertMembers(count: 3, of: album, in: context)
        let firstActive = try XCTUnwrap(album.media.first(where: { !$0.isTrashed }))
        let chosen = try XCTUnwrap(media.first(where: { $0.id != firstActive.id }))

        album.coverMediaID = chosen.id

        XCTAssertEqual(AlbumsScreen.cover(of: album)?.id, chosen.id)
    }

    func testATrashedOrMissingCoverFallsBackToTheFirstActiveMember() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = VaultAlbum(name: "Trip")
        context.insert(album)
        let media = try insertMembers(count: 3, of: album, in: context)

        album.coverMediaID = media[2].id
        media[2].trashedAt = Date()
        let fallback = AlbumsScreen.cover(of: album)

        XCTAssertNotNil(fallback)
        XCTAssertNotEqual(fallback?.id, media[2].id)
        XCTAssertEqual(fallback?.id, album.media.first(where: { !$0.isTrashed })?.id)

        album.coverMediaID = UUID()
        let fallbackForMissingCover = AlbumsScreen.cover(of: album)

        XCTAssertNotNil(fallbackForMissingCover)
        XCTAssertEqual(fallbackForMissingCover?.id, album.media.first(where: { !$0.isTrashed })?.id)
    }

    func testAnAlbumWithoutActiveMembersHasNoCover() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = VaultAlbum(name: "Trip")
        let empty = VaultAlbum(name: "Empty")
        context.insert(album)
        context.insert(empty)
        let media = try insertMembers(count: 2, of: album, in: context)

        album.coverMediaID = media[0].id
        media.forEach { $0.trashedAt = Date() }

        XCTAssertNil(AlbumsScreen.cover(of: album))
        XCTAssertNil(AlbumsScreen.cover(of: empty))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// Saves the items before linking them, so iOS 17 registers each object once.
    private func insertMembers(count: Int, of album: VaultAlbum, in context: ModelContext) throws -> [VaultMedia] {
        let media = (0..<count).map { index in
            VaultMedia(
                storageIdentifier: UUID().uuidString.lowercased(),
                contentFingerprint: UUID().uuidString,
                metadata: MediaMetadata(
                    mediaType: .photo,
                    contentTypeIdentifier: "public.jpeg",
                    originalFilename: "IMG_\(index).JPG",
                    originalCreationDate: nil,
                    pixelWidth: 10,
                    pixelHeight: 10,
                    duration: nil,
                    byteCount: 10
                )
            )
        }
        media.forEach { context.insert($0) }
        try context.save()
        media.forEach { $0.album = album }
        try context.save()
        return media
    }
}
