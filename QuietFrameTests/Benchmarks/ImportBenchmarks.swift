import XCTest
@testable import QuietFrame

/// Preparing and importing camera-sized photos through the services the import flow uses.
@MainActor
final class ImportBenchmarks: XCTestCase {
    func testMakingAThumbnailForATwelveMegapixelPhoto() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let source = try vault.writeSource(Benchmark.photoJPEG(width: 4_032, height: 3_024, seed: 8), named: "photo.jpg")
        let generator = ThumbnailGenerator()

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                let thumbnail = try await generator.jpegThumbnail(for: source, mediaType: .photo, maximumPixelSize: 720)
                XCTAssertFalse(thumbnail.isEmpty)
            }
        }
    }

    /// Eight photos with their thumbnails, with progress delivered to the main actor as the review screen does.
    func testImportingEightPhotos() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let photo = Benchmark.photoJPEG(width: 4_032, height: 3_024, seed: 9)
        let photoURL = try vault.writeSource(photo, named: "photo.jpg")
        let thumbnail = try awaitBenchmark {
            try await ThumbnailGenerator().jpegThumbnail(for: photoURL, mediaType: .photo, maximumPixelSize: 720)
        }
        let progress: @Sendable (ImportProgress) async -> Void = { update in
            await MainActor.run { _ = update.overallFraction }
        }
        var iteration = 0

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            iteration += 1
            let library: BenchmarkLibrary
            let sources: [ImportSource]
            do {
                library = try BenchmarkLibrary.make(itemCount: 0)
                sources = try (0..<8).map { index in
                    // Distinct trailing bytes give every copy its own fingerprint without changing how it decodes.
                    var copy = photo
                    copy.append(contentsOf: Array("quietframe-benchmark-\(iteration)-\(index)".utf8))
                    let url = try vault.writeSource(copy, named: "import-\(iteration)-\(index).jpg")
                    return ImportSource(
                        temporaryURL: url,
                        metadata: Benchmark.metadata(
                            filename: "IMG_\(index).JPG",
                            width: 4_032,
                            height: 3_024,
                            byteCount: Int64(copy.count)
                        ),
                        thumbnailJPEGData: thumbnail,
                        sourceLocalIdentifier: nil
                    )
                }
            } catch {
                XCTFail("Could not prepare the import: \(error)")
                return
            }
            defer { library.remove() }
            let importer = MediaImportService(
                storage: vault.storage,
                repository: VaultRepository(modelContext: library.context)
            )

            startMeasuring()
            runBenchmark {
                let summary = try await importer.importMedia(
                    sources,
                    albumID: nil,
                    preflightFailureCount: 0,
                    preflightThumbnailFailureCount: 0,
                    progress: progress
                )
                XCTAssertEqual(summary.importedCount, 8)
            }
            stopMeasuring()
        }
    }
}
