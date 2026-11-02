import XCTest
@testable import QuietFrame

/// Import preparation from picked files to the review screen, and how thumbnail work shares the machine with other
/// Swift tasks. Only APIs that exist at the baseline are used, so a same-run comparison measures each side's own code.
@MainActor
final class ImportPipelineBenchmarks: XCTestCase {
    private static let photoCount = 24

    /// Twenty-four camera-sized photos picked at once, prepared until the review can appear.
    func testPreparingTwentyFourPhotos() throws {
        try measurePreparingPhotos(metrics: [XCTClockMetric()])
    }

    /// The memory the same preparation leaves held for the review, kept apart from the timing because the comparison
    /// script averages every metric of a test together.
    func testMemoryHeldAfterPreparingTwentyFourPhotos() throws {
        try measurePreparingPhotos(metrics: [XCTMemoryMetric()])
    }

    /// Round trips through Swift's cooperative pool while a thumbnail is made on every core. Thumbnail work that holds
    /// cooperative threads makes each round trip wait for it.
    func testSmallTasksWhileThumbnailsAreMade() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let source = try vault.writeSource(Benchmark.photoJPEG(width: 4_032, height: 3_024, seed: 12), named: "photo.jpg")
        let generator = ThumbnailGenerator()
        let thumbnailCount = ProcessInfo.processInfo.activeProcessorCount

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let thumbnails = Task.detached {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    for _ in 0..<thumbnailCount {
                        group.addTask {
                            try await generator.jpegThumbnail(for: source, mediaType: .photo, maximumPixelSize: 720)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
            startMeasuring()
            runBenchmark {
                for _ in 0..<50 {
                    await Task.detached {}.value
                }
            }
            stopMeasuring()
            runBenchmark {
                try await thumbnails.value
            }
        }
    }

    private func measurePreparingPhotos(metrics: [XCTMetric]) throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let photo = Benchmark.photoJPEG(width: 4_032, height: 3_024, seed: 11)
        let names = (0..<Self.photoCount).map { "IMG_\($0).JPG" }
        let urls = try names.map { try vault.writeSource(photo, named: $0) }
        let library = try BenchmarkLibrary.make(itemCount: 0)
        defer { library.remove() }
        let viewModel = ImportViewModel(
            metadataReader: MediaMetadataService(),
            thumbnailGenerator: ThumbnailGenerator(),
            importer: MediaImportService(
                storage: vault.storage,
                repository: VaultRepository(modelContext: library.context)
            ),
            photoLibrary: PhotoLibraryService()
        )
        defer { viewModel.cleanupIfIdle() }

        measure(metrics: metrics, options: Benchmark.manualOptions) {
            let selections: [PhotoLibrarySelection] = urls.enumerated().compactMap { index, url in
                guard let provider = NSItemProvider(contentsOf: url) else { return nil }
                return PhotoLibrarySelection(
                    itemProvider: provider,
                    typeIdentifier: "public.jpeg",
                    mediaType: .photo,
                    originalFilename: names[index],
                    sourceLocalIdentifier: nil
                )
            }
            XCTAssertEqual(selections.count, names.count)
            startMeasuring()
            runBenchmark {
                viewModel.prepare(selections: selections)
                while viewModel.isPreparing {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            stopMeasuring()
            XCTAssertEqual(viewModel.candidates.map(\.source.metadata.originalFilename), names)
            viewModel.cleanupIfIdle()
        }
    }
}
