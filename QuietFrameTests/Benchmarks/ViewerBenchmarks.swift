import UIKit
import XCTest
@testable import QuietFrame

/// Opening a photo in the viewer: from the request to a decoded image the page can show.
@MainActor
final class ViewerBenchmarks: XCTestCase {
    func testOpeningATwelveMegapixelPhoto() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let jpeg = Benchmark.photoJPEG(width: 4_032, height: 3_024, seed: 7)
        let identifier = try awaitBenchmark { try await vault.store(jpeg, location: .media) }
        let request = ViewerPhotoRequest(mediaID: UUID(), storageIdentifier: identifier, location: .media)

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let loader = ViewerPhotoLoader(storage: vault.storage)
            startMeasuring()
            runBenchmark {
                loader.prepare([request])
                while loader.image(for: request.mediaID) == nil, loader.failureMessage(for: request.mediaID) == nil {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            stopMeasuring()
            XCTAssertNotNil(loader.image(for: request.mediaID))
            loader.releaseAll()
        }
    }
}
