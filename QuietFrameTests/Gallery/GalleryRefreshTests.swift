import Observation
import SwiftData
import XCTest
@testable import QuietFrame

/// Refreshes skip the fetch while nothing a fetch depends on has changed, and write only what did change.
@MainActor
final class GalleryRefreshTests: XCTestCase {
    func testRefreshWithoutALibraryChangeWritesNothing() async throws {
        let fixture = try makeFixture(count: 5)
        let viewModel = albumViewModel(fixture, pageSize: 2)
        await viewModel.loadInitial()

        await assertNothingObservedChanges(in: viewModel) {
            await viewModel.refreshLoadedItems()
        }

        XCTAssertEqual(identifiers(of: viewModel), ["5", "4"])
        XCTAssertTrue(viewModel.hasMore)
    }

    func testRefreshWithoutALibraryChangeFetchesNothing() async throws {
        let fixture = try makeFixture(count: 3)
        let viewModel = albumViewModel(fixture, pageSize: 80)
        await viewModel.loadInitial()
        let loaded = viewModel.itemIDs
        // The app never saves an edit without recording it; this one only shows whether the refresh fetched.
        let first = try XCTUnwrap(viewModel.items.first)
        first.trashedAt = Date()
        try fixture.container.mainContext.save()

        await viewModel.refreshLoadedItems()

        XCTAssertEqual(viewModel.itemIDs, loaded)
    }

    func testRefreshAfterARecordedEditFetches() async throws {
        let fixture = try makeFixture(count: 5)
        let viewModel = albumViewModel(fixture, pageSize: 2)
        await viewModel.loadInitial()
        try await loadNextPage(of: viewModel)
        let kept = try fixture.item(named: "5")
        let moved = try fixture.item(named: "4")
        viewModel.beginSelection(with: kept.id)
        viewModel.beginSelection(with: moved.id)

        try fixture.repository.moveMedia(ids: [moved.id], toAlbumID: nil)
        await viewModel.refreshLoadedItems()

        XCTAssertEqual(identifiers(of: viewModel), ["5", "3", "2", "1"])
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(viewModel.selectedIDs, [kept.id])
        XCTAssertEqual(viewModel.itemIDs, viewModel.items.map(\.id))
    }

    func testAppendedPageUnderTheSameSignatureKeepsTheSkip() async throws {
        let fixture = try makeFixture(count: 5)
        let viewModel = albumViewModel(fixture, pageSize: 2)
        await viewModel.loadInitial()
        try await loadNextPage(of: viewModel)

        await assertNothingObservedChanges(in: viewModel) {
            await viewModel.refreshLoadedItems()
        }

        XCTAssertEqual(identifiers(of: viewModel), ["5", "4", "3", "2"])
        XCTAssertTrue(viewModel.hasMore)
    }

    func testPageAppendedAfterAnEditMakesTheNextRefreshFetch() async throws {
        let fixture = try makeFixture(count: 5)
        let viewModel = albumViewModel(fixture, pageSize: 2)
        await viewModel.loadInitial()
        let unloaded = try fixture.item(named: "2")
        try fixture.repository.moveMedia(ids: [unloaded.id], toAlbumID: nil)
        try await loadNextPage(of: viewModel)

        await viewModel.refreshLoadedItems()

        let fresh = try fixture.repository.fetchMedia(query: viewModel.query, offset: 0, limit: viewModel.items.count)
        XCTAssertEqual(viewModel.itemIDs, fresh.items.map(\.id))
        XCTAssertEqual(identifiers(of: viewModel), ["5", "4", "3", "1"])
    }

    func testPageAppendedUnderAnotherQueryMakesTheNextRefreshFetch() async throws {
        let fixture = try makeFixture(count: 5)
        let viewModel = albumViewModel(fixture, pageSize: 2)
        await viewModel.loadInitial()
        viewModel.query.dateSortDirection = .oldestFirst
        try await loadNextPage(of: viewModel)
        viewModel.query.dateSortDirection = .newestFirst

        await viewModel.refreshLoadedItems()

        XCTAssertEqual(identifiers(of: viewModel), ["5", "4", "3", "2"])
        XCTAssertTrue(viewModel.hasMore)
    }

    func testRecentlyAddedRefreshesWithoutAnEdit() async throws {
        let fixture = try makeFixture(count: 0)
        let now = Date()
        let newer = try insertMedia(named: "newer", importedAt: now.addingTimeInterval(-86_400), into: fixture)
        let older = try insertMedia(named: "older", importedAt: now.addingTimeInterval(-2 * 86_400), into: fixture)
        let viewModel = GalleryViewModel(repository: fixture.repository, query: GalleryQuery(collection: .recentlyAdded))
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.itemIDs, [newer.id, older.id])

        // Stands in for the clock passing the 30-day cutoff, which moves without any save.
        older.importedAt = now.addingTimeInterval(-31 * 86_400)
        try fixture.container.mainContext.save()
        await viewModel.refreshLoadedItems()

        XCTAssertEqual(viewModel.itemIDs, [newer.id])
    }

    func testSkippedRefreshKeepsTheSelectionAndClearsAnError() async throws {
        let fixture = try makeFixture(count: 3)
        let viewModel = albumViewModel(fixture, pageSize: 80)
        await viewModel.loadInitial()
        let selected = Set(viewModel.itemIDs.prefix(2))
        for id in selected {
            viewModel.beginSelection(with: id)
        }
        let generation = fixture.repository.changes.generation
        viewModel.setFavorite(mediaID: UUID(), isFavorite: true)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(fixture.repository.changes.generation, generation)

        await viewModel.refreshLoadedItems()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.selectedIDs, selected)
        XCTAssertTrue(viewModel.isSelecting)
        XCTAssertEqual(identifiers(of: viewModel), ["3", "2", "1"])
    }

    func testSkippedRefreshStillDropsASelectionThatIsNotLoaded() async throws {
        let fixture = try makeFixture(count: 3)
        let viewModel = albumViewModel(fixture, pageSize: 80)
        await viewModel.loadInitial()
        let loaded = try XCTUnwrap(viewModel.itemIDs.first)
        viewModel.beginSelection(with: loaded)
        viewModel.beginSelection(with: UUID())

        await viewModel.refreshLoadedItems()

        XCTAssertEqual(viewModel.selectedIDs, [loaded])
    }

    func testSearchRefreshIsSkippedUntilTheLibraryChanges() async throws {
        let fixture = try makeFixture(count: 5)
        let viewModel = GalleryViewModel(
            repository: fixture.repository,
            query: GalleryQuery(sort: .name, searchText: "Holiday"),
            pageSize: 2
        )
        await viewModel.loadInitial()
        try await loadNextPage(of: viewModel)
        XCTAssertEqual(identifiers(of: viewModel), ["1", "2", "3", "4"])

        await assertNothingObservedChanges(in: viewModel) {
            await viewModel.refreshLoadedItems()
        }

        try fixture.repository.renameAlbum(id: fixture.album.id, name: "Archive")
        await viewModel.refreshLoadedItems()

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
    }

    func testRefreshThatFetchesTheLoadedItemsAgainWritesNothing() async throws {
        let fixture = try makeFixture(count: 3)
        let viewModel = albumViewModel(fixture, pageSize: 80)
        await viewModel.loadInitial()
        let favorite = try XCTUnwrap(viewModel.itemIDs.first)
        try fixture.repository.setFavorite(mediaID: favorite, isFavorite: true)

        await assertNothingObservedChanges(in: viewModel) {
            await viewModel.refreshLoadedItems()
        }

        XCTAssertEqual(identifiers(of: viewModel), ["3", "2", "1"])
    }

    func testItemIDsFollowTheItems() async throws {
        let fixture = try makeFixture(count: 5)
        let viewModel = albumViewModel(fixture, pageSize: 2)

        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.itemIDs, viewModel.items.map(\.id))
        try await loadNextPage(of: viewModel)
        XCTAssertEqual(viewModel.itemIDs, viewModel.items.map(\.id))
        try fixture.repository.moveMedia(ids: [viewModel.itemIDs[1]], toAlbumID: nil)
        await viewModel.refreshLoadedItems()
        XCTAssertEqual(viewModel.itemIDs, viewModel.items.map(\.id))
        XCTAssertEqual(viewModel.index(of: viewModel.itemIDs[2]), 2)

        let failing = GalleryViewModel(repository: fixture.repository, query: viewModel.query, pageSize: 0)
        await failing.loadInitial()
        XCTAssertNotNil(failing.errorMessage)
        XCTAssertTrue(failing.items.isEmpty)
        XCTAssertTrue(failing.itemIDs.isEmpty)
    }

    private struct Fixture {
        let container: ModelContainer
        let repository: VaultRepository
        let album: VaultAlbum
        let media: [VaultMedia]

        func item(named name: String) throws -> VaultMedia {
            try XCTUnwrap(media.first { $0.storageIdentifier == name })
        }
    }

    /// An album "Holiday" with items "1" to "count", imported in that order.
    private func makeFixture(count: Int) throws -> Fixture {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let album = VaultAlbum(name: "Holiday")
        context.insert(album)
        try context.save()
        let media = (0..<count).map { index in
            VaultMedia(
                storageIdentifier: "\(index + 1)",
                contentFingerprint: "fingerprint-\(index + 1)",
                metadata: Benchmark.metadata(filename: "\(index + 1).jpg", width: 100, height: 100, byteCount: 100),
                importedAt: Date(timeIntervalSince1970: TimeInterval((index + 1) * 100)),
                album: album
            )
        }
        media.forEach { context.insert($0) }
        try context.save()
        return Fixture(
            container: container,
            repository: VaultRepository(modelContext: context),
            album: album,
            media: media
        )
    }

    private func insertMedia(named name: String, importedAt: Date, into fixture: Fixture) throws -> VaultMedia {
        let media = VaultMedia(
            storageIdentifier: name,
            contentFingerprint: "fingerprint-\(name)",
            metadata: Benchmark.metadata(filename: "\(name).jpg", width: 100, height: 100, byteCount: 100),
            importedAt: importedAt
        )
        fixture.container.mainContext.insert(media)
        try fixture.container.mainContext.save()
        return media
    }

    private func albumViewModel(_ fixture: Fixture, pageSize: Int) -> GalleryViewModel {
        GalleryViewModel(
            repository: fixture.repository,
            query: GalleryQuery(collection: nil, albumID: fixture.album.id),
            pageSize: pageSize
        )
    }

    private func loadNextPage(of viewModel: GalleryViewModel) async throws {
        let last = try XCTUnwrap(viewModel.items.last)
        await viewModel.loadNextIfNeeded(currentItem: last)
    }

    private func identifiers(of viewModel: GalleryViewModel) -> [String] {
        viewModel.items.map(\.storageIdentifier)
    }

    /// Fails when `work` writes any of the state that the grid and the screens read.
    private func assertNothingObservedChanges(in viewModel: GalleryViewModel, during work: () async -> Void) async {
        let changed = expectation(description: "Observed gallery state changed")
        changed.isInverted = true
        withObservationTracking {
            _ = viewModel.items
            _ = viewModel.itemIDs
            _ = viewModel.hasMore
            _ = viewModel.isLoading
            _ = viewModel.hasLoaded
            _ = viewModel.errorMessage
            _ = viewModel.selectedIDs
            _ = viewModel.isSelecting
        } onChange: {
            changed.fulfill()
        }
        await work()
        await fulfillment(of: [changed], timeout: 0.2)
    }
}
