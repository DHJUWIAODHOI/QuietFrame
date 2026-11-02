import XCTest
@testable import QuietFrame

/// Import preparation from picked files to the review screen, and how thumbnail work shares the machine with other
/// Swift tasks. Apart from the review-layout variants, only APIs that exist at 2ce13cd are used, so a same-run
/// comparison against it measures each side's own code.
@MainActor
final class ImportPipelineBenchmarks: XCTestCase {
    private static let photoCount = 24

    /// Twenty-four camera-sized photos picked at once, prepared until the review can appear. No review layout is
    /// set, so this build decodes no previews here; the review-layout variant includes them.
    func testPreparingTwentyFourPhotos() throws {
        try measurePreparingPhotos(metrics: [XCTClockMetric()])
    }

    /// The same preparation with the review's first screen decoded before it appears, as in the app.
    func testPreparingTwentyFourPhotosForTheReviewScreen() throws {
        try measurePreparingPhotos(metrics: [XCTClockMetric()], layout: Self.reviewLayout)
    }

    /// The memory the same preparation leaves held for the review, kept apart from the timing because the comparison
    /// script averages every metric of a test together.
    func testMemoryHeldAfterPreparingTwentyFourPhotos() throws {
        try measurePreparingPhotos(metrics: [XCTMemoryMetric()])
    }

    /// The memory held once the review's first screen of previews is decoded too.
    func testMemoryHeldAfterPreparingTwentyFourPhotosForTheReviewScreen() throws {
        try measurePreparingPhotos(metrics: [XCTMemoryMetric()], layout: Self.reviewLayout)
    }

    /// An iPhone 16 Pro review grid: 114-point tiles at 3x, nine rows of three on the first screen.
    private static let reviewLayout = ImportPreviewLayout(tileWidth: 114, scale: 3, firstScreenCount: 27)

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

    private func measurePreparingPhotos(metrics: [XCTMetric], layout: ImportPreviewLayout? = nil) throws {
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
        viewModel.previewLayout = layout
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
