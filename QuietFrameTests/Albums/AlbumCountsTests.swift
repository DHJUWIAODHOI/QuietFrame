import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class AlbumCountsTests: XCTestCase {
    func testChangesWhileTheScreenIsHiddenAreCountedWhenItAppears() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = VaultAlbum(name: "Trip")
        context.insert(album)
        let media = try insertMedia(count: 4, in: context)
        media[0].album = album
        try context.save()
        let counts = AlbumCounts()
        counts.screenDidAppear(in: context, albumIDs: [album.id])
        XCTAssertEqual([counts.allCount, counts.favoriteCount, counts.count(forAlbum: album.id)], [4, 0, 1])

        counts.screenDidDisappear()
        media[1].album = album
        media[2].isFavorite = true
        media[3].trashedAt = Date()
        try context.save()
        counts.libraryDidChange(in: context, albumIDs: [album.id])

        XCTAssertEqual([counts.allCount, counts.favoriteCount, counts.count(forAlbum: album.id)], [4, 0, 1])

        counts.screenDidAppear(in: context, albumIDs: [album.id])

        XCTAssertEqual([counts.allCount, counts.favoriteCount, counts.count(forAlbum: album.id)], [3, 1, 2])
    }

    func testChangesWhileTheScreenIsVisibleAreCountedAtOnce() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = VaultAlbum(name: "Trip")
        context.insert(album)
        let media = try insertMedia(count: 3, in: context)
        let counts = AlbumCounts()
        counts.screenDidAppear(in: context, albumIDs: [album.id])
        counts.screenDidDisappear()
        counts.screenDidAppear(in: context, albumIDs: [album.id])

        media[0].album = album
        media[1].album = album
        media[2].isFavorite = true
        let newAlbum = VaultAlbum(name: "New")
        context.insert(newAlbum)
        try context.save()
        counts.libraryDidChange(in: context, albumIDs: [album.id, newAlbum.id])

        XCTAssertEqual(counts.favoriteCount, 1)
        XCTAssertEqual(counts.albumCounts, [album.id: 2, newAlbum.id: 0])
    }

    func testChangesBeforeTheFirstAppearanceWaitForIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertMedia(count: 2, in: context)
        let counts = AlbumCounts()

        counts.libraryDidChange(in: context, albumIDs: [])
        XCTAssertEqual(counts.allCount, 0)

        counts.screenDidAppear(in: context, albumIDs: [])
        XCTAssertEqual(counts.allCount, 2)
    }

    func testEveryAppearanceCountsAgainWithoutAReportedChange() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let media = try insertMedia(count: 3, in: context, importedAt: now.addingTimeInterval(-20 * 86_400))
        let counts = AlbumCounts()
        counts.screenDidAppear(in: context, albumIDs: [], now: now)
        XCTAssertEqual([counts.allCount, counts.recentCount], [3, 3])

        context.delete(media[0])
        try context.save()
        counts.screenDidAppear(in: context, albumIDs: [], now: now)
        XCTAssertEqual([counts.allCount, counts.recentCount], [2, 2])

        counts.screenDidDisappear()
        counts.screenDidAppear(in: context, albumIDs: [], now: now.addingTimeInterval(11 * 86_400))
        XCTAssertEqual([counts.allCount, counts.recentCount], [2, 0])
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func insertMedia(
        count: Int,
        in context: ModelContext,
        importedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> [VaultMedia] {
        let media = (0..<count).map { index in
            VaultMedia(
                storageIdentifier: UUID().uuidString.lowercased(),
                contentFingerprint: "fingerprint-\(index)",
                metadata: MediaMetadata(
                    mediaType: .photo,
                    contentTypeIdentifier: "public.jpeg",
                    originalFilename: "IMG_\(index).JPG",
                    originalCreationDate: nil,
                    pixelWidth: 10,
                    pixelHeight: 10,
                    duration: nil,
                    byteCount: 10
                ),
                importedAt: importedAt
            )
        }
        media.forEach { context.insert($0) }
        try context.save()
        return media
    }
}
