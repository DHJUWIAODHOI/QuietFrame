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

    func testImportProgressNeverWaitsForTheMainThread() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = ProgressReportingImporter(updateCount: 200)
        let viewModel = try await makePreparedViewModel(importer: importer, directory: directory)
        defer { viewModel.cancelPreparation() }

        viewModel.startImport()
        await fulfillment(of: [importer.started], timeout: 30)
        let reportedWhileMainWasBlocked = blockMainThread(until: importer.finishedReporting)

        XCTAssertTrue(reportedWhileMainWasBlocked, "Encryption must not wait for the main thread to show its progress.")
        for _ in 0..<1_000 where viewModel.isImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isImporting)
        XCTAssertEqual(viewModel.progress, ImportProgress(completedItems: 1, totalItems: 1, currentItemFraction: 0))
        XCTAssertEqual(viewModel.summary?.importedCount, 1)
    }

    private func makePreparedViewModel(importer: any MediaImporting, directory: URL) async throws -> ImportViewModel {
        let url = directory.appendingPathComponent("photo.jpg")
        try Benchmark.photoJPEG(width: 64, height: 48, seed: 9).write(to: url)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
        let viewModel = ImportViewModel(
            metadataReader: DelayedMetadataReader(delays: [0]),
            thumbnailGenerator: FixedThumbnailGenerator(failingData: Data()),
            importer: importer,
            photoLibrary: IdlePhotoLibrary()
        )
        viewModel.prepare(selections: [PhotoLibrarySelection(
            itemProvider: provider,
            typeIdentifier: "public.jpeg",
            mediaType: .photo,
            originalFilename: "photo.jpg",
            sourceLocalIdentifier: "asset-0"
        )])
        for _ in 0..<1_000 where viewModel.isPreparing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(viewModel.candidates.count, 1)
        return viewModel
    }

    /// Holds the main thread, as a long render would, until `semaphore` is signalled or 20 seconds pass.
    private func blockMainThread(until semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 20) == .success
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

/// Reports a run of progress values from off the main thread, then succeeds. It signals when it starts and when it
/// has reported everything, so a test can hold the main thread in between.
private final class ProgressReportingImporter: MediaImporting, @unchecked Sendable {
    let started = XCTestExpectation(description: "The import started")
    let finishedReporting = DispatchSemaphore(value: 0)
    private let updateCount: Int

    init(updateCount: Int) {
        self.updateCount = updateCount
    }

    func importMedia(
        _ sources: [ImportSource],
        albumID: UUID?,
        preflightFailureCount: Int,
        preflightThumbnailFailureCount: Int,
        progress: (@Sendable (ImportProgress) async -> Void)?
    ) async throws -> ImportSummary {
        sources.forEach { IncomingMediaFileStore.remove($0.temporaryURL) }
        started.fulfill()
        for update in 1...updateCount {
            await progress?(ImportProgress(
                completedItems: 0,
                totalItems: sources.count,
                currentItemFraction: 0.9 * Double(update) / Double(updateCount)
            ))
        }
        await progress?(ImportProgress(completedItems: sources.count, totalItems: sources.count, currentItemFraction: 0))
        finishedReporting.signal()
        var summary = ImportSummary()
        summary.importedCount = sources.count
        summary.importedSourceLocalIdentifiers = sources.compactMap(\.sourceLocalIdentifier)
        return summary
    }

    func cleanupAbandonedIncomingFiles() async {}

    func cancelAllOperations() async {}
}
