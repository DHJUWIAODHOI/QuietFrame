import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class GallerySortingTests: XCTestCase {
    func testDateImportedNewestFirst() throws {
        let fixture = try makeFixture([
            ("old", 100, 100),
            ("new", 300, 300),
            ("middle", 200, 200)
        ])

        XCTAssertEqual(
            try identifiers(in: fixture, sort: .importedAt, direction: .newestFirst),
            ["new", "middle", "old"]
        )
    }

    func testDateImportedOldestFirst() throws {
        let fixture = try makeFixture([
            ("old", 100, 100),
            ("new", 300, 300),
            ("middle", 200, 200)
        ])

        XCTAssertEqual(
            try identifiers(in: fixture, sort: .importedAt, direction: .oldestFirst),
            ["old", "middle", "new"]
        )
    }

    func testDateCreatedNewestFirst() throws {
        let fixture = try makeFixture([
            ("old-import", 100, 200),
            ("new-created", 200, 300),
            ("new-import", 300, 200)
        ])

        XCTAssertEqual(
            try identifiers(in: fixture, sort: .createdAt, direction: .newestFirst),
            ["new-created", "new-import", "old-import"]
        )
    }

    func testDateCreatedOldestFirst() throws {
        let fixture = try makeFixture([
            ("old-import", 100, 200),
            ("new-created", 200, 300),
            ("new-import", 300, 200)
        ])

        XCTAssertEqual(
            try identifiers(in: fixture, sort: .createdAt, direction: .oldestFirst),
            ["old-import", "new-import", "new-created"]
        )
    }

    func testEqualDatesUseStorageIdentifierAscending() throws {
        let fixture = try makeFixture([
            ("c", 100, 100),
            ("a", 100, 100),
            ("b", 100, 100)
        ])

        for direction in MediaDateSortDirection.allCases {
            XCTAssertEqual(
                try identifiers(in: fixture, sort: .importedAt, direction: direction),
                ["a", "b", "c"]
            )
            XCTAssertEqual(
                try identifiers(in: fixture, sort: .createdAt, direction: direction),
                ["a", "b", "c"]
            )
        }
    }

    func testMultiPageOrderingIsCompleteAndStable() throws {
        let fixture = try makeFixture([
            ("d", 100, 100),
            ("a", 100, 100),
            ("f", 100, 100),
            ("c", 100, 100),
            ("b", 100, 100),
            ("e", 100, 100)
        ])
        let query = albumQuery(fixture, sort: .importedAt, direction: .newestFirst)
        var identifiers: [String] = []
        var offset = 0
        var hasMore = true

        while hasMore {
            let page = try fixture.repository.fetchMedia(query: query, offset: offset, limit: 2)
            identifiers.append(contentsOf: page.items.map(\.storageIdentifier))
            offset += page.items.count
            hasMore = page.hasMore
        }

        XCTAssertEqual(identifiers, ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testSearchPreservesDateOrdering() throws {
        let fixture = try makeFixture([
            ("match-old", 100, 100),
            ("match-new", 300, 300),
            ("match-middle", 200, 200)
        ])
        var query = albumQuery(fixture, sort: .importedAt, direction: .oldestFirst)
        query.searchText = "match"

        XCTAssertEqual(
            try fixture.repository.fetchMedia(query: query, offset: 0, limit: 10).items.map(\.storageIdentifier),
            ["match-old", "match-middle", "match-new"]
        )
    }

    func testDateCreatedKeepsMissingDatesInTheirExistingGroups() throws {
        let fixture = try makeFixture([
            ("dated", 100, 100),
            ("missing-new", 300, nil),
            ("missing-old", 200, nil)
        ])

        XCTAssertEqual(
            try identifiers(in: fixture, sort: .createdAt, direction: .newestFirst),
            ["dated", "missing-new", "missing-old"]
        )
        XCTAssertEqual(
            try identifiers(in: fixture, sort: .createdAt, direction: .oldestFirst),
            ["missing-old", "missing-new", "dated"]
        )
    }

    func testNonDateSortDirectionsRemainUnchanged() throws {
        let fixture = try makeFixture([
            ("small-video", 300, 300),
            ("large-photo", 100, 100),
            ("middle-photo", 200, 200)
        ])
        let media = try fixture.container.mainContext.fetch(FetchDescriptor<VaultMedia>())
        let smallVideo = try XCTUnwrap(media.first { $0.storageIdentifier == "small-video" })
        let largePhoto = try XCTUnwrap(media.first { $0.storageIdentifier == "large-photo" })
        let middlePhoto = try XCTUnwrap(media.first { $0.storageIdentifier == "middle-photo" })
        smallVideo.mediaTypeRawValue = "video"
        smallVideo.byteCount = 100
        largePhoto.byteCount = 300
        middlePhoto.byteCount = 200
        try fixture.container.mainContext.save()

        XCTAssertEqual(
            try identifiers(in: fixture, sort: .name, direction: .oldestFirst),
            ["large-photo", "middle-photo", "small-video"]
        )
        XCTAssertEqual(
            try identifiers(in: fixture, sort: .size, direction: .oldestFirst),
            ["large-photo", "middle-photo", "small-video"]
        )
        XCTAssertEqual(
            try identifiers(in: fixture, sort: .type, direction: .oldestFirst),
            ["middle-photo", "large-photo", "small-video"]
        )
    }

    func testChangingDirectionResetsPagination() async throws {
        let fixture = try makeFixture([
            ("1", 100, 100),
            ("2", 200, 200),
            ("3", 300, 300),
            ("4", 400, 400),
            ("5", 500, 500)
        ])
        let viewModel = GalleryViewModel(
            repository: fixture.repository,
            query: albumQuery(fixture, sort: .importedAt, direction: .newestFirst),
            pageSize: 2
        )

        await viewModel.loadInitial()
        await viewModel.loadNextIfNeeded(currentItem: try XCTUnwrap(viewModel.items.last))
        XCTAssertEqual(viewModel.items.map(\.storageIdentifier), ["5", "4", "3", "2"])

        await viewModel.updateDateSortDirection(.oldestFirst)

        XCTAssertEqual(viewModel.items.map(\.storageIdentifier), ["1", "2"])
        XCTAssertTrue(viewModel.hasMore)
    }

    func testViewerReceivesItemsInSelectedOrder() async throws {
        let fixture = try makeFixture([
            ("old", 100, 100),
            ("new", 300, 300),
            ("middle", 200, 200)
        ])
        let viewModel = GalleryViewModel(
            repository: fixture.repository,
            query: albumQuery(fixture, sort: .importedAt, direction: .oldestFirst)
        )

        await viewModel.loadInitial()

        XCTAssertEqual(viewModel.items.map(\.storageIdentifier), ["old", "middle", "new"])
    }

    func testNewSettingsDefaultToNewestFirst() {
        XCTAssertEqual(AppSettings().albumMediaDateSortDirection, .newestFirst)
        XCTAssertEqual(GalleryQuery().dateSortDirection, .newestFirst)
    }

    func testSelectedDirectionPersistsAfterStoreReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Vault.store")

        try autoreleasepool {
            let container = try makeLatestContainer(at: storeURL)
            let settings = AppSettings(albumMediaDateSortDirection: .oldestFirst)
            container.mainContext.insert(settings)
            try container.mainContext.save()
        }

        try autoreleasepool {
            let container = try makeLatestContainer(at: storeURL)
            let settings = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<AppSettings>()).first)
            XCTAssertEqual(settings.albumMediaDateSortDirection, .oldestFirst)
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let repository: VaultRepository
        let album: VaultAlbum
    }

    private func makeFixture(_ values: [(identifier: String, importedAt: TimeInterval, createdAt: TimeInterval?)]) throws -> Fixture {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let album = VaultAlbum(name: "Test")
        container.mainContext.insert(album)
        for value in values {
            container.mainContext.insert(VaultMedia(
                storageIdentifier: value.identifier,
                contentFingerprint: "fingerprint-\(value.identifier)",
                metadata: MediaMetadata(
                    mediaType: .photo,
                    contentTypeIdentifier: "public.jpeg",
                    originalFilename: "\(value.identifier).jpg",
                    originalCreationDate: value.createdAt.map { Date(timeIntervalSince1970: $0) },
                    pixelWidth: 100,
                    pixelHeight: 100,
                    duration: nil,
                    byteCount: 100
                ),
                importedAt: Date(timeIntervalSince1970: value.importedAt),
                album: album
            ))
        }
        try container.mainContext.save()
        return Fixture(
            container: container,
            repository: VaultRepository(modelContext: container.mainContext),
            album: album
        )
    }

    private func makeLatestContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: VaultSchemaV3.self)
        let configuration = ModelConfiguration("GallerySortingTest", schema: schema, url: storeURL)
        return try ModelContainer(
            for: schema,
            migrationPlan: VaultMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private func albumQuery(
        _ fixture: Fixture,
        sort: MediaSortOption,
        direction: MediaDateSortDirection
    ) -> GalleryQuery {
        GalleryQuery(
            collection: nil,
            albumID: fixture.album.id,
            sort: sort,
            dateSortDirection: direction
        )
    }

    private func identifiers(
        in fixture: Fixture,
        sort: MediaSortOption,
        direction: MediaDateSortDirection
    ) throws -> [String] {
        try fixture.repository.fetchMedia(
            query: albumQuery(fixture, sort: sort, direction: direction),
            offset: 0,
            limit: 20
        ).items.map(\.storageIdentifier)
    }
}
