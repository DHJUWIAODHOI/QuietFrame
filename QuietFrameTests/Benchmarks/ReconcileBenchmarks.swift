import SwiftData
import XCTest
@testable import QuietFrame

/// The main thread while the reconciliation after every unlock reads the references of a 5,000-item library.
@MainActor
final class ReconcileBenchmarks: XCTestCase {
    private let itemCount = 5_000

    /// How long a main-actor job queued as reconciliation starts waits for it, with references read in pages of 500.
    func testMainThreadWaitAsReconciliationStarts() throws {
        try measureMainThreadWaitAsReconciliationStarts(pageSize: 500)
    }

    /// The same wait with every reference read in one fetch, as reconciliation read them before it used pages.
    func testMainThreadWaitAsReconciliationStartsInOneFetch() throws {
        try measureMainThreadWaitAsReconciliationStarts(pageSize: 10_000)
    }

    private func measureMainThreadWaitAsReconciliationStarts(pageSize: Int) throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let files = try referencedFiles(in: ModelContext(library.container))
        let service = StorageReconciliationService(
            modelContext: library.context,
            storage: MockSecureFileStorage(identifiers: files),
            pageSize: pageSize
        )

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let reconciliation = Task { try await service.reconcile() }
            runBenchmark {}
            waitForReconciliationToQueueItsFirstStep()
            startMeasuring()
            runBenchmark {}
            stopMeasuring()
            runBenchmark {
                let result = try await reconciliation.value
                XCTAssertEqual(result, ReconciliationResult(repairedLocations: 0, deletedOrphans: 0, missingFiles: 0))
            }
        }
    }

    /// Reconciliation takes the operation gate off the main actor, so the first `runBenchmark` only lets it start. This
    /// pause lets its first main-actor step queue up ahead of the measured job.
    private func waitForReconciliationToQueueItsFirstStep() {
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func referencedFiles(in context: ModelContext) throws -> [EncryptedAssetLocation: Set<String>] {
        var files: [EncryptedAssetLocation: Set<String>] = [.media: [], .trash: [], .thumbnails: []]
        for media in try context.fetch(FetchDescriptor<VaultMedia>()) {
            let location: EncryptedAssetLocation = media.isTrashed ? .trash : .media
            files[location, default: []].insert(media.storageIdentifier)
            if let thumbnailIdentifier = media.thumbnailIdentifier {
                files[.thumbnails, default: []].insert(thumbnailIdentifier)
            }
        }
        return files
    }
}
