import SwiftData
import XCTest
@testable import QuietFrame

/// Metadata work on a 5,000-item library in an on-disk store: gallery pages, search, the refresh after the viewer
/// closes, a Trash move, the unlock backstop and the Albums tab's counts.
@MainActor
final class LibraryBenchmarks: XCTestCase {
    private let itemCount = 5_000

    func testOpeningTheGallery() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let repository = VaultRepository(modelContext: library.context)

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            XCTAssertEqual((try? repository.fetchMedia(query: GalleryQuery(), offset: 0, limit: 80))?.items.count, 80)
        }
    }

    func testScrollingDeepIntoTheGallery() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let repository = VaultRepository(modelContext: library.context)

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            XCTAssertEqual(
                (try? repository.fetchMedia(query: GalleryQuery(), offset: 2_400, limit: 80))?.items.count,
                80
            )
        }
    }

    /// The first page of a new search; no iteration starts with the previous one's kept results.
    func testSearchingTheGallery() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let repository = VaultRepository(modelContext: library.context)
        let query = GalleryQuery(searchText: "IMG_12")

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            repository.clearSearchSnapshot()
            startMeasuring()
            let count = (try? repository.fetchMedia(query: query, offset: 0, limit: 80))?.items.count
            stopMeasuring()
            XCTAssertEqual(count, 80)
        }
    }

    /// Closing the viewer after scrolling through five pages with nothing changed. The original app fetched every
    /// loaded item again; the refresh is now skipped. GalleryBenchmarks covers a refresh after an edit.
    func testRefreshingFivePagesAfterTheViewerCloses() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let viewModel = GalleryViewModel(
            repository: VaultRepository(modelContext: library.context),
            query: GalleryQuery(),
            pageSize: 400
        )
        try awaitBenchmark { await viewModel.loadInitial() }
        XCTAssertEqual(viewModel.items.count, 400)

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark { await viewModel.refreshLoadedItems() }
        }
        XCTAssertEqual(viewModel.items.count, 400)
    }

    func testMovingFiftyItemsToTheTrash() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let service = TrashService(modelContext: library.context, storage: MockSecureFileStorage())
        var activeDescriptor = FetchDescriptor<VaultMedia>(
            predicate: #Predicate { $0.trashedAt == nil },
            sortBy: [SortDescriptor(\VaultMedia.importedAt, order: .reverse)]
        )
        activeDescriptor.fetchLimit = 50
        let ids = Set(try library.context.fetch(activeDescriptor).map(\.id))
        XCTAssertEqual(ids.count, 50)

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            startMeasuring()
            runBenchmark { try await service.moveToTrash(ids: ids) }
            stopMeasuring()
            runBenchmark { try await service.restore(ids: ids) }
        }
    }

    /// The reconciliation every unlock waits for, against real files in the vault's directory layout.
    func testReconcilingStorageAfterUnlock() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        try createPlaceholderFiles(for: library, in: vault)
        let service = StorageReconciliationService(modelContext: library.context, storage: vault.storage)

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                let result = try await service.reconcile()
                XCTAssertEqual(result, ReconciliationResult(repairedLocations: 0, deletedOrphans: 0, missingFiles: 0))
            }
        }
    }

    /// The Trash tab purges expired items, behind the operation gate, every time it appears.
    func testTrashTabPurgeCheck() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        library.context.insert(AppSettings(trashRetentionPeriod: .thirtyDays))
        try library.context.save()
        let service = TrashService(modelContext: library.context, storage: MockSecureFileStorage())

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark { _ = try await service.purgeExpiredItems() }
        }
    }

    /// The Albums tab's first appearance with counts from the store: the album list, the counts and the covers, in a
    /// fresh context. The tab counts again when it appears, when its albums change and after each saved edit.
    func testAlbumsTabCountsInTheStore() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let counts = AlbumCounts()

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let context = ModelContext(library.container)
            startMeasuring()
            let albums = (try? context.fetch(FetchDescriptor<VaultAlbum>(sortBy: [SortDescriptor(\.position)]))) ?? []
            counts.refresh(in: context, albumIDs: albums.map(\.id))
            let covers = albums.filter { $0.benchmarkCover != nil }.count
            stopMeasuring()
            withExtendedLifetime((context, albums)) {}
            XCTAssertGreaterThan(counts.allCount + covers, 0)
        }
    }

    /// The Albums tab's first appearance before the counts moved into the store: the active-media query behind the
    /// three collection counts, then each album row's count and cover, in a fresh context.
    func testAlbumsTabCounts() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let context = ModelContext(library.container)
            startMeasuring()
            let activeMedia = (try? context.fetch(FetchDescriptor<VaultMedia>(
                predicate: #Predicate { $0.trashedAt == nil }
            ))) ?? []
            let albums = (try? context.fetch(FetchDescriptor<VaultAlbum>(sortBy: [SortDescriptor(\.position)]))) ?? []
            let allCount = activeMedia.count
            let recentCount = activeMedia.lazy.filter { $0.importedAt >= cutoff }.count
            let favoriteCount = activeMedia.lazy.filter(\.isFavorite).count
            var albumCounts = 0
            var covers = 0
            for album in albums {
                albumCounts += album.activeMediaCount
                if album.benchmarkCover != nil {
                    covers += 1
                }
            }
            stopMeasuring()
            withExtendedLifetime((context, activeMedia, albums)) {}
            XCTAssertGreaterThan(allCount + recentCount + favoriteCount + albumCounts + covers, 0)
        }
    }

    /// Five pages of one search, as scrolling through the results loads them.
    func testPagingThroughFiveSearchPages() throws {
        try measurePagingThroughFiveSearchPages(savingBetweenPages: false)
    }

    /// The same five pages with a save before each one, so every page scans the library again, as every page did
    /// before searches kept their results.
    func testPagingThroughFiveSearchPagesWithSavesInBetween() throws {
        try measurePagingThroughFiveSearchPages(savingBetweenPages: true)
    }

    private func measurePagingThroughFiveSearchPages(savingBetweenPages: Bool) throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let repository = VaultRepository(modelContext: library.context)
        let query = GalleryQuery(searchText: "IMG_")
        let album = library.albums[0]

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            repository.clearSearchSnapshot()
            startMeasuring()
            runBenchmark {
                for page in 0..<5 {
                    if savingBetweenPages {
                        album.modifiedAt = Date()
                        try library.context.save()
                        await Task.yield()
                    }
                    let result = try repository.fetchMedia(query: query, offset: page * 80, limit: 80)
                    XCTAssertEqual(result.items.count, 80)
                }
            }
            stopMeasuring()
        }
    }

    private func createPlaceholderFiles(for library: BenchmarkLibrary, in vault: BenchmarkVault) throws {
        let root = vault.directory
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent("QuietFrameVault", isDirectory: true)
        let fileManager = FileManager.default
        for media in try library.context.fetch(FetchDescriptor<VaultMedia>()) {
            let folder = media.isTrashed ? "trash" : "media"
            let mediaPath = root.appendingPathComponent(folder).appendingPathComponent("\(media.storageIdentifier).qfe")
            XCTAssertTrue(fileManager.createFile(atPath: mediaPath.path, contents: nil))
            if let thumbnailIdentifier = media.thumbnailIdentifier {
                let thumbnailPath = root.appendingPathComponent("thumbnails")
                    .appendingPathComponent("\(thumbnailIdentifier).qfe")
                XCTAssertTrue(fileManager.createFile(atPath: thumbnailPath.path, contents: nil))
            }
        }
    }
}

private extension VaultAlbum {
    /// AlbumCover's rule in AlbumsScreen: the chosen cover while it is active, otherwise the first active member.
    var benchmarkCover: VaultMedia? {
        if let coverMediaID, let selected = media.first(where: { $0.id == coverMediaID && !$0.isTrashed }) {
            return selected
        }
        return media.first(where: { !$0.isTrashed })
    }
}
