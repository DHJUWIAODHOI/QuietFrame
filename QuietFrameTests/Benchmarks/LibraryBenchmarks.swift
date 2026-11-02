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

    func testSearchingTheGallery() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let repository = VaultRepository(modelContext: library.context)
        let query = GalleryQuery(searchText: "IMG_12")

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            XCTAssertEqual((try? repository.fetchMedia(query: query, offset: 0, limit: 80))?.items.count, 80)
        }
    }

    /// Closing the viewer after scrolling through five pages re-fetches every loaded item.
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

    /// The work AlbumsScreen does each time its body is evaluated: the active-media query behind the three
    /// collection counts, then each album row's count and cover.
    func testAlbumsTabCounts() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let context = library.context
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            guard let activeMedia = try? context.fetch(FetchDescriptor<VaultMedia>(
                predicate: #Predicate { $0.trashedAt == nil }
            )),
                let albums = try? context.fetch(FetchDescriptor<VaultAlbum>(sortBy: [SortDescriptor(\.position)]))
            else {
                XCTFail("The library could not be fetched.")
                return
            }
            let allCount = activeMedia.count
            let recentCount = activeMedia.lazy.filter { $0.importedAt >= cutoff }.count
            let favoriteCount = activeMedia.lazy.filter(\.isFavorite).count
            var albumCounts = 0
            var covers = 0
            for album in albums {
                albumCounts += album.activeMediaCount
                if album.media.first(where: { !$0.isTrashed }) != nil {
                    covers += 1
                }
            }
            XCTAssertGreaterThan(allCount + recentCount + favoriteCount + albumCounts + covers, 0)
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
