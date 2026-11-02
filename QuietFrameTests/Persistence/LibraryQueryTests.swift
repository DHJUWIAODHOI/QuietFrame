import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class LibraryQueryTests: XCTestCase {
    func testFetchingByIDsReturnsExactlyThoseMediaAcrossBatches() throws {
        let container = try makeContainer()
        let media = insertMedia(count: 1_200, in: container)
        let requested = media.prefix(1_100).map(\.id)

        let fetched = try container.mainContext.fetchMedia(ids: requested + requested.prefix(10) + [UUID()])

        XCTAssertEqual(fetched.count, 1_100)
        XCTAssertEqual(Set(fetched.map(\.id)), Set(requested))
    }

    func testFetchingNoIDsFetchesNothing() throws {
        let container = try makeContainer()
        _ = insertMedia(count: 3, in: container)

        XCTAssertTrue(try container.mainContext.fetchMedia(ids: [UUID]()).isEmpty)
    }

    func testExportKeepsTheRequestedOrderAndRejectsMissingItems() throws {
        let container = try makeContainer()
        let media = insertMedia(count: 5, in: container)
        let repository = VaultRepository(modelContext: container.mainContext)
        let order = [media[3].id, media[0].id, media[4].id]

        XCTAssertEqual(
            try repository.exportItems(ids: order).map(\.storageIdentifier),
            [media[3], media[0], media[4]].map(\.storageIdentifier)
        )
        XCTAssertThrowsError(try repository.exportItems(ids: [media[1].id, UUID()]))
    }

    func testBulkFavoriteChangesEveryItemInOneSave() throws {
        let container = try makeContainer()
        let album = VaultAlbum(name: "Trip", createdAt: Date(timeIntervalSince1970: 1_000))
        container.mainContext.insert(album)
        let media = insertMedia(count: 4, in: container)
        media[0].album = album
        try container.mainContext.save()
        let repository = VaultRepository(modelContext: container.mainContext)

        try repository.setFavorite(mediaIDs: [media[0].id, media[2].id], isFavorite: true)

        XCTAssertEqual(media.map(\.isFavorite), [true, false, true, false])
        XCTAssertGreaterThan(album.modifiedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testBulkFavoriteChangesNothingWhenAnItemIsMissing() throws {
        let container = try makeContainer()
        let media = insertMedia(count: 3, in: container)
        let repository = VaultRepository(modelContext: container.mainContext)

        XCTAssertThrowsError(try repository.setFavorite(mediaIDs: [media[0].id, UUID()], isFavorite: true))

        XCTAssertEqual(media.map(\.isFavorite), [false, false, false])
    }

    func testSearchPagesMatchOneFullScan() throws {
        let container = try makeContainer()
        _ = insertMedia(count: 40, in: container)
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery(searchText: "IMG_001")

        let fullScan = try repository.fetchMedia(query: query, offset: 0, limit: 1_000).items.map(\.id)
        var paged: [UUID] = []
        var offset = 0
        var hasMore = true
        while hasMore {
            let page = try repository.fetchMedia(query: query, offset: offset, limit: 3)
            paged += page.items.map(\.id)
            offset += page.items.count
            hasMore = page.hasMore
        }

        XCTAssertFalse(fullScan.isEmpty)
        XCTAssertEqual(paged, fullScan)
    }

    func testLaterSearchPagesReuseTheFirstPagesResultsUntilTheLibraryChanges() throws {
        let container = try makeContainer()
        let media = insertMedia(count: 6, in: container)
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery(sort: .name, searchText: "IMG_")

        let firstPage = try repository.fetchMedia(query: query, offset: 0, limit: 3)
        XCTAssertEqual(firstPage.items.map(\.id), [media[0].id, media[1].id, media[2].id])
        // Filenames never change in the app; this one only shows whether the next page rescans.
        media[4].originalFilename = "renamed.jpg"
        try container.mainContext.save()

        let cachedPage = try repository.fetchMedia(query: query, offset: 3, limit: 3)
        XCTAssertEqual(cachedPage.items.map(\.id), [media[3].id, media[4].id, media[5].id])

        try repository.setFavorite(mediaID: media[1].id, isFavorite: true)
        let rescannedPage = try repository.fetchMedia(query: query, offset: 3, limit: 3)
        XCTAssertEqual(rescannedPage.items.map(\.id), [media[3].id, media[5].id])
        XCTAssertFalse(rescannedPage.hasMore)
    }

    func testSearchRescansWhenAnItemLeavesTheScopeOrAnAlbumIsRenamed() async throws {
        let container = try makeContainer()
        let album = VaultAlbum(name: "Holiday")
        container.mainContext.insert(album)
        let media = insertMedia(count: 6, in: container)
        media.forEach { $0.album = album }
        try container.mainContext.save()
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery(sort: .name, searchText: "Holiday")

        XCTAssertEqual(try repository.fetchMedia(query: query, offset: 0, limit: 3).items.count, 3)
        try await TrashService(modelContext: container.mainContext, storage: MockSecureFileStorage())
            .moveToTrash(ids: [media[3].id])
        XCTAssertEqual(
            try repository.fetchMedia(query: query, offset: 3, limit: 3).items.map(\.id),
            [media[4].id, media[5].id]
        )

        try repository.renameAlbum(id: album.id, name: "Archive")
        XCTAssertTrue(try repository.fetchMedia(query: query, offset: 3, limit: 3).items.isEmpty)
    }

    func testSearchRescansAfterAnAppEditEvenWhenAnotherItemIsStampedInTheFuture() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let future = Date().addingTimeInterval(365 * 86_400)
        let pinned = VaultAlbum(name: "Pinned")
        let holiday = VaultAlbum(name: "Holiday")
        let other = VaultAlbum(name: "Other")
        pinned.modifiedAt = future
        [pinned, holiday, other].forEach { context.insert($0) }
        let media = insertMedia(count: 7, in: container)
        media.prefix(6).forEach { $0.album = holiday }
        media[6].album = pinned
        media[6].modifiedAt = future
        try context.save()
        let repository = VaultRepository(modelContext: context)
        let query = GalleryQuery(sort: .name, searchText: "Holiday")

        XCTAssertEqual(try repository.fetchMedia(query: query, offset: 0, limit: 3).items.count, 3)
        try repository.moveMedia(ids: [media[4].id], toAlbumID: other.id)

        XCTAssertEqual(
            try repository.fetchMedia(query: query, offset: 3, limit: 3).items.map(\.id),
            [media[3].id, media[5].id]
        )
    }

    func testLaterPagesOfOneSearchIgnoreAnotherSearchsResults() throws {
        let container = try makeContainer()
        let media = insertMedia(count: 40, in: container)
        let repository = VaultRepository(modelContext: container.mainContext)
        let first = GalleryQuery(sort: .name, searchText: "IMG_000")
        let second = GalleryQuery(sort: .name, searchText: "IMG_001")

        XCTAssertEqual(try repository.fetchMedia(query: first, offset: 0, limit: 3).items.map(\.id), media[0..<3].map(\.id))
        XCTAssertEqual(try repository.fetchMedia(query: second, offset: 0, limit: 3).items.map(\.id), media[10..<13].map(\.id))

        let laterPage = try repository.fetchMedia(query: first, offset: 3, limit: 3)
        XCTAssertEqual(laterPage.items.map(\.id), media[3..<6].map(\.id))
        XCTAssertTrue(laterPage.hasMore)
    }

    func testTheFirstSearchPageReusesTheScanUntilTheLibraryChanges() throws {
        let container = try makeContainer()
        let media = insertMedia(count: 6, in: container)
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery(sort: .name, searchText: "IMG_")

        XCTAssertEqual(try repository.fetchMedia(query: query, offset: 0, limit: 6).items.count, 6)
        // Filenames never change in the app; this unstamped rename leaves the fingerprint as it was.
        media[4].originalFilename = "renamed.jpg"
        try container.mainContext.save()
        XCTAssertEqual(
            try repository.fetchMedia(query: query, offset: 0, limit: 6).items.map(\.id),
            media.map(\.id)
        )

        repository.changes.recordChange()
        let refreshed = try repository.fetchMedia(query: query, offset: 0, limit: 6)
        XCTAssertEqual(refreshed.items.map(\.id), [media[0].id, media[1].id, media[2].id, media[3].id, media[5].id])
        XCTAssertFalse(refreshed.hasMore)
    }

    func testClearingTheSearchSnapshotMakesTheNextPageScanAgain() throws {
        let container = try makeContainer()
        let media = insertMedia(count: 6, in: container)
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery(sort: .name, searchText: "IMG_")
        XCTAssertEqual(try repository.fetchMedia(query: query, offset: 0, limit: 3).items.count, 3)
        // Filenames never change in the app; this unstamped rename only shows whether the next page rescans.
        media[4].originalFilename = "renamed.jpg"
        try container.mainContext.save()

        repository.clearSearchSnapshot()

        XCTAssertEqual(
            try repository.fetchMedia(query: query, offset: 3, limit: 3).items.map(\.id),
            [media[3].id, media[5].id]
        )
    }

    func testARecentlyAddedSearchScansAgainOnceAnItemAgesOut() throws {
        let container = try makeContainer()
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86_400)
        let media = insertMedia(count: 3, in: container, importedFrom: threeDaysAgo, step: 86_400)
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery(collection: .recentlyAdded, sort: .name, searchText: "IMG_")
        XCTAssertEqual(try repository.fetchMedia(query: query, offset: 0, limit: 3).items.map(\.id), media.map(\.id))

        // Stands in for the clock passing the 30-day cutoff, which moves without any save.
        media[0].importedAt = Date().addingTimeInterval(-31 * 86_400)
        try container.mainContext.save()

        let refreshed = try repository.fetchMedia(query: query, offset: 0, limit: 3)
        XCTAssertEqual(refreshed.items.map(\.id), [media[1].id, media[2].id])
        XCTAssertFalse(refreshed.hasMore)
    }

    func testMovingAnUnfiledItemIntoAnAlbumShowsOnTheNextSearchPage() throws {
        let container = try makeContainer()
        let album = VaultAlbum(name: "Holiday")
        container.mainContext.insert(album)
        let media = insertMedia(count: 6, in: container)
        media.prefix(5).forEach { $0.album = album }
        try container.mainContext.save()
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery(sort: .name, searchText: "Holiday")

        XCTAssertEqual(
            try repository.fetchMedia(query: query, offset: 0, limit: 3).items.map(\.id),
            media.prefix(3).map(\.id)
        )
        try repository.moveMedia(ids: [media[5].id], toAlbumID: album.id)

        XCTAssertEqual(media[5].album?.id, album.id)
        let nextPage = try repository.fetchMedia(query: query, offset: 3, limit: 3)
        XCTAssertEqual(nextPage.items.map(\.id), [media[3].id, media[4].id, media[5].id])
        XCTAssertFalse(nextPage.hasMore)
    }

    func testMovingTrashedOrMissingItemsThrowsAndMovesNothing() throws {
        let container = try makeContainer()
        let album = VaultAlbum(name: "Holiday")
        container.mainContext.insert(album)
        let media = insertMedia(count: 2, in: container)
        media[1].trashedAt = Date()
        try container.mainContext.save()
        let repository = VaultRepository(modelContext: container.mainContext)

        XCTAssertThrowsError(try repository.moveMedia(ids: [media[0].id, media[1].id], toAlbumID: album.id)) {
            XCTAssertEqual($0 as? VaultError, .persistenceFailure)
        }
        XCTAssertThrowsError(try repository.moveMedia(ids: [media[0].id, UUID()], toAlbumID: album.id)) {
            XCTAssertEqual($0 as? VaultError, .persistenceFailure)
        }
        XCTAssertNil(media[0].album)
    }

    /// Galleries skip refreshes while the counter stands still, so every path that saves media or albums moves it.
    func testEveryLibraryWritePathMovesTheChangeCounter() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(AppSettings(trashRetentionPeriod: .sevenDays))
        try context.save()
        let changes = LibraryChangeCounter()
        let repository = VaultRepository(modelContext: context, changes: changes)
        let storage = MockSecureFileStorage()
        let trash = TrashService(modelContext: context, storage: storage, changes: changes)
        let albums = AlbumService(repository: repository, modelContext: context, storage: storage)
        var generations = [changes.generation]
        let album = try repository.createAlbum(name: "Holiday")
        generations.append(changes.generation)
        let media = insertMedia(count: 8, in: container)

        try repository.setFavorite(mediaID: media[0].id, isFavorite: true)
        generations.append(changes.generation)
        try repository.setFavorite(mediaIDs: [media[1].id, media[2].id], isFavorite: true)
        generations.append(changes.generation)
        try repository.moveMedia(ids: [media[1].id, media[3].id], toAlbumID: album.id)
        generations.append(changes.generation)
        try repository.setAlbumCover(albumID: album.id, mediaID: media[1].id)
        generations.append(changes.generation)
        try repository.renameAlbum(id: album.id, name: "Archive")
        generations.append(changes.generation)
        let second = try albums.createAlbum(name: "Second")
        generations.append(changes.generation)
        try repository.reorderAlbums(ids: [second.id, album.id])
        generations.append(changes.generation)
        let importedID = try repository.insertImportedMedia(
            storageIdentifier: "imported",
            thumbnailIdentifier: nil,
            fingerprint: "imported-fingerprint",
            metadata: Benchmark.metadata(filename: "IMPORTED.JPG", width: 10, height: 10, byteCount: 10),
            albumID: second.id
        )
        generations.append(changes.generation)
        try repository.deleteImportedMedia(id: importedID)
        generations.append(changes.generation)
        try await trash.moveToTrash(ids: [media[4].id])
        generations.append(changes.generation)
        try await trash.restore(ids: [media[4].id])
        generations.append(changes.generation)
        try await trash.moveToTrash(ids: [media[4].id])
        generations.append(changes.generation)
        try await trash.permanentlyDelete(ids: [media[4].id])
        generations.append(changes.generation)
        try await trash.moveToTrash(ids: [media[5].id])
        generations.append(changes.generation)
        try await trash.emptyTrash()
        generations.append(changes.generation)
        try await trash.moveToTrash(ids: [media[6].id])
        generations.append(changes.generation)
        media[6].trashedAt = Date().addingTimeInterval(-8 * 86_400)
        try context.save()
        let purged = try await trash.purgeExpiredItems()
        XCTAssertEqual(purged.deletedCount, 1)
        generations.append(changes.generation)
        try await albums.deleteAlbum(id: second.id, mode: .keepMedia)
        generations.append(changes.generation)
        try await albums.deleteAlbum(id: album.id, mode: .moveMediaToTrash)
        generations.append(changes.generation)

        XCTAssertEqual(generations, generations.sorted())
        XCTAssertEqual(Set(generations).count, generations.count)
    }

    func testFetchSignatureFollowsEveryResultInput() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let query = GalleryQuery()
        let signature = try XCTUnwrap(repository.fetchSignature(for: query))

        XCTAssertEqual(repository.fetchSignature(for: query), signature)
        XCTAssertEqual(signature.localeIdentifier, Locale.current.identifier)
        XCTAssertEqual(signature.timeZoneIdentifier, TimeZone.current.identifier)
        XCTAssertEqual(signature.calendarIdentifier, Calendar.current.identifier)
        XCTAssertNil(signature.mediumDateSample)
        XCTAssertNotEqual(repository.fetchSignature(for: GalleryQuery(filter: .videos)), signature)
        XCTAssertNil(repository.fetchSignature(for: GalleryQuery(searchText: "  "))?.mediumDateSample)
        let search = try XCTUnwrap(repository.fetchSignature(for: GalleryQuery(searchText: "IMG")))
        XCTAssertNotNil(search.mediumDateSample)
        XCTAssertEqual(repository.fetchSignature(for: GalleryQuery(searchText: "IMG")), search)

        repository.changes.recordChange()

        XCTAssertNotEqual(repository.fetchSignature(for: query), signature)
        XCTAssertNotEqual(repository.fetchSignature(for: GalleryQuery(searchText: "IMG")), search)
    }

    func testOnlyTheRecentlyAddedCollectionDependsOnTheClock() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)

        XCTAssertNil(repository.fetchSignature(for: GalleryQuery(collection: .recentlyAdded)))
        XCTAssertNil(repository.fetchSignature(for: GalleryQuery(collection: .recentlyAdded, filter: .videos)))
        XCTAssertNotNil(repository.fetchSignature(for: GalleryQuery(collection: .recentlyAdded, albumID: UUID())))
        XCTAssertNotNil(repository.fetchSignature(for: GalleryQuery(collection: .recentlyAdded, includesTrash: true)))
        XCTAssertNotNil(repository.fetchSignature(for: GalleryQuery(collection: .favorites)))
        XCTAssertNotNil(repository.fetchSignature(for: GalleryQuery(collection: nil, albumID: UUID())))
    }

    func testAlbumCountsMatchTheItemsTheyDescribe() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let albums = [VaultAlbum(name: "One"), VaultAlbum(name: "Two"), VaultAlbum(name: "Empty")]
        albums.forEach { context.insert($0) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let media = insertMedia(count: 12, in: container, importedFrom: now.addingTimeInterval(-40 * 86_400), step: 5 * 86_400)
        for (index, item) in media.enumerated() {
            item.album = albums[index % 2]
            item.isFavorite = index % 3 == 0
        }
        media[1].trashedAt = now
        media[3].trashedAt = now
        media[3].album = nil
        try context.save()
        let counts = AlbumCounts()

        counts.refresh(in: context, albumIDs: albums.map(\.id), now: now)

        let active = media.filter { $0.trashedAt == nil }
        let cutoff = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -30, to: now))
        XCTAssertEqual(counts.allCount, active.count)
        XCTAssertEqual(counts.recentCount, active.filter { $0.importedAt >= cutoff }.count)
        XCTAssertEqual(counts.favoriteCount, active.filter(\.isFavorite).count)
        for album in albums {
            XCTAssertEqual(counts.count(forAlbum: album.id), album.activeMediaCount, album.name)
        }
        XCTAssertEqual(counts.count(forAlbum: albums[2].id), 0)
        XCTAssertEqual([counts.allCount, counts.recentCount, counts.favoriteCount], [10, 9, 3])
        XCTAssertEqual(albums.map { counts.count(forAlbum: $0.id) }, [6, 4, 0])
    }

    func testIdentifierListingKeepsOnlyVaultFileNames() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x21, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session),
            baseURL: directory,
            temporaryBaseURL: directory.appendingPathComponent("Caches", isDirectory: true),
            applyFileProtection: false
        )
        let media = directory.appendingPathComponent("QuietFrameVault/media", isDirectory: true)
        let lowercase = UUID().uuidString.lowercased()
        let uppercase = UUID().uuidString.uppercased()
        let names = [
            "\(lowercase).qfe",
            "\(uppercase).qfe",
            ".\(UUID().uuidString.lowercased()).qfe",
            "\(UUID().uuidString.lowercased()).QFE",
            "not-an-identifier.qfe",
            "\(UUID().uuidString.lowercased()).partial",
            "\(UUID().uuidString.lowercased()).qfe.tmp"
        ]
        for name in names {
            XCTAssertTrue(FileManager.default.createFile(atPath: media.appendingPathComponent(name).path, contents: nil))
        }

        let identifiers = try await storage.allIdentifiers(location: .media)

        XCTAssertEqual(identifiers, [lowercase, uppercase])
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func insertMedia(
        count: Int,
        in container: ModelContainer,
        importedFrom start: Date = Date(timeIntervalSince1970: 1_700_000_000),
        step: TimeInterval = 60
    ) -> [VaultMedia] {
        let media = (0..<count).map { index in
            VaultMedia(
                storageIdentifier: UUID().uuidString.lowercased(),
                contentFingerprint: "fingerprint-\(index)",
                metadata: Benchmark.metadata(
                    filename: String(format: "IMG_%04ld.JPG", index),
                    width: 10,
                    height: 10,
                    byteCount: 10
                ),
                importedAt: start.addingTimeInterval(TimeInterval(index) * step)
            )
        }
        media.forEach { container.mainContext.insert($0) }
        try? container.mainContext.save()
        return media
    }
}
