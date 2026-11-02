import UIKit
import XCTest
@testable import QuietFrame

@MainActor
final class ImportPreparationTests: XCTestCase {
    func testPreparationRunsInParallelAndKeepsTheSelectionOrder() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = (0..<6).map { "photo-\($0).jpg" }
        let selections: [PhotoLibrarySelection] = try names.enumerated().map { index, name in
            let url = directory.appendingPathComponent(name)
            try Benchmark.photoJPEG(width: 64, height: 48, seed: UInt64(index + 1)).write(to: url)
            let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
            return PhotoLibrarySelection(
                itemProvider: provider,
                typeIdentifier: "public.jpeg",
                mediaType: .photo,
                originalFilename: name,
                sourceLocalIdentifier: "asset-\(index)"
            )
        }
        let metadataReader = DelayedMetadataReader(delays: [0.12, 0.02, 0.09, 0.01, 0.06, 0.03])
        let viewModel = ImportViewModel(
            metadataReader: metadataReader,
            thumbnailGenerator: FixedThumbnailGenerator(
                failingData: try Data(contentsOf: directory.appendingPathComponent("photo-2.jpg"))
            ),
            importer: IdleImporter(),
            photoLibrary: IdlePhotoLibrary()
        )
        defer { viewModel.cancelPreparation() }

        viewModel.prepare(selections: selections)
        XCTAssertEqual(viewModel.preparationTotal, 6)
        for _ in 0..<1_000 where viewModel.isPreparing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(viewModel.isPreparing)
        XCTAssertEqual(viewModel.preparedCount, 6)
        XCTAssertEqual(viewModel.candidates.map(\.source.metadata.originalFilename), names)
        XCTAssertEqual(viewModel.candidates.map(\.source.sourceLocalIdentifier), (0..<6).map { "asset-\($0)" })
        XCTAssertEqual(viewModel.candidates.map(\.thumbnailFailed), [false, false, true, false, false, false])
        XCTAssertTrue(viewModel.candidates.allSatisfy { FileManager.default.fileExists(atPath: $0.source.temporaryURL.path) })
        XCTAssertEqual(viewModel.userMessage, "1 preview could not be generated.")
        let maximumConcurrentReads = await metadataReader.maximumConcurrentReads
        XCTAssertGreaterThan(maximumConcurrentReads, 1)
        XCTAssertLessThanOrEqual(maximumConcurrentReads, 3)
    }
}

private actor DelayedMetadataReader: MediaMetadataReading {
    private let delays: [TimeInterval]
    private var activeReads = 0
    private(set) var maximumConcurrentReads = 0

    init(delays: [TimeInterval]) {
        self.delays = delays
    }

    func metadata(for url: URL, mediaType: MediaType, originalFilename: String?) async throws -> MediaMetadata {
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        let index = Int(originalFilename?.filter(\.isNumber) ?? "") ?? 0
        try await Task.sleep(nanoseconds: UInt64(delays[index % delays.count] * 1_000_000_000))
        return MediaMetadata(
            mediaType: mediaType,
            contentTypeIdentifier: "public.jpeg",
            originalFilename: originalFilename,
            originalCreationDate: nil,
            pixelWidth: 64,
            pixelHeight: 48,
            duration: nil,
            byteCount: 1_000
        )
    }
}

/// Returns each item's own bytes as its preview, and fails for one item, recognised by its contents because the
/// incoming copy has a random name.
private struct FixedThumbnailGenerator: ThumbnailGenerating {
    let failingData: Data

    func jpegThumbnail(for url: URL, mediaType: MediaType, maximumPixelSize: Int) async throws -> Data {
        let data = try Data(contentsOf: url)
        guard data != failingData else { throw VaultError.thumbnailFailed }
        return data
    }
}

private actor IdleImporter: MediaImporting {
    func importMedia(
        _ sources: [ImportSource],
        albumID: UUID?,
        preflightFailureCount: Int,
        preflightThumbnailFailureCount: Int,
        progress: (@Sendable (ImportProgress) async -> Void)?
    ) async throws -> ImportSummary {
        throw VaultError.importFailed
    }

    func cleanupAbandonedIncomingFiles() async {}

    func cancelAllOperations() async {}
}

private actor IdlePhotoLibrary: PhotoLibraryServing {
    func requestImportAccess() async -> PhotoLibraryImportAccess {
        .full
    }

    func deleteOriginals(localIdentifiers: [String]) async throws {}
}
