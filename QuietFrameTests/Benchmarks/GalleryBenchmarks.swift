import SwiftData
import XCTest
@testable import QuietFrame

/// Gallery data flow on a 5,000-item library in an on-disk store: refreshes after an edit and with a search
/// loaded, the scan behind a new search, and the viewer's position lookups.
@MainActor
final class GalleryBenchmarks: XCTestCase {
    private let itemCount = 5_000

    /// Closing the viewer after an edit re-fetches the five loaded pages; the items come back unchanged.
    func testRefreshingFivePagesAfterAnEdit() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let repository = VaultRepository(modelContext: library.context)
        let viewModel = GalleryViewModel(repository: repository, query: GalleryQuery(), pageSize: 400)
        try awaitBenchmark { await viewModel.loadInitial() }
        XCTAssertEqual(viewModel.items.count, 400)

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            repository.changes.recordChange()
            startMeasuring()
            runBenchmark { await viewModel.refreshLoadedItems() }
            stopMeasuring()
        }
        XCTAssertEqual(viewModel.items.count, 400)
    }

    /// Closing the viewer with three pages of a search loaded and nothing changed.
    func testRefreshingThreeSearchPagesAfterTheViewerCloses() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let viewModel = GalleryViewModel(
            repository: VaultRepository(modelContext: library.context),
            query: GalleryQuery(searchText: "IMG_"),
            pageSize: 80
        )
        runBenchmark {
            await viewModel.loadInitial()
            for _ in 0..<2 {
                guard let last = viewModel.items.last else { return }
                await viewModel.loadNextIfNeeded(currentItem: last)
            }
        }
        XCTAssertEqual(viewModel.items.count, 240)

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark { await viewModel.refreshLoadedItems() }
        }
        XCTAssertEqual(viewModel.items.count, 240)
    }

    /// The scan behind the first page of a new search. A change recorded before each run keeps the previous run's
    /// matches from being reused.
    func testScanningForTheFirstPageOfASearch() throws {
        try measureFirstSearchPage(searchText: "IMG_12", expectedCount: 80)
    }

    /// A search that matches nothing compares every field of every item.
    func testScanningForASearchWithNoMatches() throws {
        try measureFirstSearchPage(searchText: "Nothing matches", expectedCount: 0)
    }

    /// The pager and chrome look up the selected item several times per render, also after it has left the list.
    func testLookingUpAMissingItemAmongTenThousand() {
        let ids = (0..<10_000).map { _ in UUID() }
        let missing = UUID()
        let positions = MediaPositionIndex()
        XCTAssertEqual(positions.index(of: ids[5_000], in: ids), 5_000)

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            var found = 0
            for _ in 0..<1_000 {
                if positions.index(of: missing, in: ids) != nil {
                    found += 1
                }
            }
            XCTAssertEqual(found, 0)
        }
    }

    private func measureFirstSearchPage(searchText: String, expectedCount: Int) throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let repository = VaultRepository(modelContext: library.context)
        let query = GalleryQuery(searchText: searchText)

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            repository.changes.recordChange()
            startMeasuring()
            let count = (try? repository.fetchMedia(query: query, offset: 0, limit: 80))?.items.count
            stopMeasuring()
            XCTAssertEqual(count, expectedCount)
        }
    }
}
