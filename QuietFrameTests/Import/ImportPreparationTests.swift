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
        let reportedWhileMainWasBlocked = blockMainThread(whileReporting: importer)

        XCTAssertTrue(reportedWhileMainWasBlocked, "Encryption must not wait for the main thread to show its progress.")
        for _ in 0..<1_000 where viewModel.isImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isImporting)
        XCTAssertEqual(viewModel.progress, ImportProgress(completedItems: 1, totalItems: 1, currentItemFraction: 0))
        XCTAssertEqual(viewModel.summary?.importedCount, 1)
    }

    func testPendingChecksResolveOnceInSelectionOrder() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checks = (0..<4).map { PhotoLibraryDeletionCheck.pending(assetIdentifier: "a\($0)", providerHasLivePhoto: false) }
        let selections = try makeSelections(count: 4, in: directory) { checks[$0] }
        let photoLibrary = RecordingPhotoLibrary(answers: ["a0", nil, "a2", nil])
        let viewModel = makeViewModel(photoLibrary: photoLibrary)
        defer { viewModel.cancelPreparation() }

        viewModel.prepare(selections: selections)
        try await waitUntilPrepared(viewModel)

        let requests = await photoLibrary.requests
        XCTAssertEqual(requests, [checks])
        XCTAssertEqual(viewModel.candidates.map(\.source.sourceLocalIdentifier), ["a0", nil, "a2", nil])
        XCTAssertEqual(viewModel.userMessage, "automatic deletion is unavailable for 2 items in this selection.")
    }

    func testDecidedSelectionsNeverAskThePhotoLibrary() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selections = try makeSelections(count: 3, in: directory) { index in
            PhotoLibraryDeletionCheck.resolved(index == 1 ? nil : "asset-\(index)")
        }
        let photoLibrary = RecordingPhotoLibrary(answers: [])
        let viewModel = makeViewModel(photoLibrary: photoLibrary)
        defer { viewModel.cancelPreparation() }

        viewModel.prepare(selections: selections)
        try await waitUntilPrepared(viewModel)

        let requests = await photoLibrary.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(viewModel.candidates.map(\.source.sourceLocalIdentifier), ["asset-0", nil, "asset-2"])
        XCTAssertEqual(viewModel.userMessage, "automatic deletion is unavailable for 1 item in this selection.")
    }

    func testAShortAnswerFromThePhotoLibraryNeverOffersDeletion() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selections = try makeSelections(count: 3, in: directory) { index in
            PhotoLibraryDeletionCheck.pending(assetIdentifier: "a\(index)", providerHasLivePhoto: false)
        }
        let viewModel = makeViewModel(photoLibrary: RecordingPhotoLibrary(answers: ["a0"]))
        defer { viewModel.cancelPreparation() }

        viewModel.prepare(selections: selections)
        try await waitUntilPrepared(viewModel)

        XCTAssertEqual(viewModel.candidates.map(\.source.sourceLocalIdentifier), ["a0", nil, nil])
        XCTAssertEqual(viewModel.userMessage, "automatic deletion is unavailable for 2 items in this selection.")
    }

    /// The deletion warning counts every picked item, including one that then fails to prepare.
    func testDeletionWarningCountsItemsThatFailToPrepare() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifiers: [String?] = [nil, nil, "asset-2"]
        let selections: [PhotoLibrarySelection] = try identifiers.enumerated().map { index, identifier in
            let name = "photo-\(index).jpg"
            let url = directory.appendingPathComponent(name)
            try Benchmark.photoJPEG(width: 64, height: 48, seed: UInt64(index + 1)).write(to: url)
            return PhotoLibrarySelection(
                itemProvider: try XCTUnwrap(NSItemProvider(contentsOf: url)),
                typeIdentifier: "public.jpeg",
                mediaType: .photo,
                originalFilename: name,
                sourceLocalIdentifier: identifier
            )
        }
        let viewModel = ImportViewModel(
            metadataReader: DelayedMetadataReader(delays: [0], failingIndices: [1]),
            thumbnailGenerator: FixedThumbnailGenerator(failingData: Data()),
            importer: IdleImporter(),
            photoLibrary: IdlePhotoLibrary()
        )
        defer { viewModel.cancelPreparation() }

        viewModel.prepare(selections: selections)
        try await waitUntilPrepared(viewModel)

        XCTAssertEqual(viewModel.candidates.map(\.source.metadata.originalFilename), ["photo-0.jpg", "photo-2.jpg"])
        XCTAssertEqual(
            viewModel.userMessage,
            "automatic deletion is unavailable for 2 items in this selection; 1 item could not be prepared."
        )
    }

    func testPreparationDecodesOnlyTheFirstScreenBeforeShowingTheReview() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selections = try makeSelections(count: 6, in: directory, width: 720, height: 540) { _ in .resolved(nil) }
        let viewModel = makeViewModel(photoLibrary: IdlePhotoLibrary())
        defer { viewModel.cancelPreparation() }
        viewModel.previewLayout = ImportPreviewLayout(tileWidth: 114, scale: 3, firstScreenCount: 2)

        viewModel.prepare(selections: selections)
        try await waitUntilPrepared(viewModel)

        let candidates = viewModel.candidates
        XCTAssertEqual(candidates.count, 6)
        for candidate in candidates.prefix(2) {
            XCTAssertEqual(viewModel.previewImages.cachedImage(for: candidate.id, atLeast: 512)?.cgImage?.width, 512)
        }
        for candidate in candidates.dropFirst(2) {
            XCTAssertNil(viewModel.previewImages.cachedImage(for: candidate.id, atLeast: 1))
        }
        XCTAssertEqual(viewModel.previewImages.decodeCount, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.source.thumbnailJPEGData != nil })
    }

    func testRemovingACandidateAndFinishingTheImportReleasePreviews() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selections = try makeSelections(count: 3, in: directory, width: 720, height: 540) { _ in .resolved(nil) }
        let viewModel = makeViewModel(photoLibrary: IdlePhotoLibrary(), importer: CompletingImporter())
        defer { viewModel.cancelPreparation() }
        viewModel.previewLayout = ImportPreviewLayout(tileWidth: 114, scale: 3, firstScreenCount: 3)
        viewModel.prepare(selections: selections)
        try await waitUntilPrepared(viewModel)
        let ids = viewModel.candidates.map(\.id)
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.allSatisfy { viewModel.previewImages.cachedImage(for: $0, atLeast: 512) != nil })

        viewModel.removeCandidate(id: ids[1])

        XCTAssertNil(viewModel.previewImages.cachedImage(for: ids[1], atLeast: 1))
        XCTAssertNotNil(viewModel.previewImages.cachedImage(for: ids[0], atLeast: 512))

        viewModel.startImport()
        for _ in 0..<1_000 where viewModel.isImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(viewModel.summary?.importedCount, 2)
        XCTAssertTrue(viewModel.candidates.isEmpty)
        XCTAssertTrue(ids.allSatisfy { viewModel.previewImages.cachedImage(for: $0, atLeast: 1) == nil })
    }

    func testRemovedAndClosedCandidatesLoseTheirIncomingCopies() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selections = try makeSelections(count: 3, in: directory) { _ in .resolved(nil) }
        let viewModel = makeViewModel(photoLibrary: IdlePhotoLibrary())
        defer { viewModel.cancelPreparation() }
        viewModel.prepare(selections: selections)
        try await waitUntilPrepared(viewModel)
        let urls = viewModel.candidates.map(\.source.temporaryURL)
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        viewModel.removeCandidate(id: viewModel.candidates[0].id)
        try await waitUntilRemoved(urls[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[1].path))

        viewModel.cleanupIfIdle()
        XCTAssertTrue(viewModel.candidates.isEmpty)
        try await waitUntilRemoved(urls[1])
        try await waitUntilRemoved(urls[2])
    }

    private func waitUntilRemoved(_ url: URL) async throws {
        for _ in 0..<1_000 where FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) was not removed")
    }

    private func makeViewModel(
        photoLibrary: any PhotoLibraryServing,
        importer: any MediaImporting = IdleImporter()
    ) -> ImportViewModel {
        ImportViewModel(
            metadataReader: DelayedMetadataReader(delays: [0]),
            thumbnailGenerator: FixedThumbnailGenerator(failingData: Data()),
            importer: importer,
            photoLibrary: photoLibrary
        )
    }

    /// Photos written to `directory` and picked in order, each with its own deletion check.
    private func makeSelections(
        count: Int,
        in directory: URL,
        width: Int = 64,
        height: Int = 48,
        deletionCheck: (Int) -> PhotoLibraryDeletionCheck
    ) throws -> [PhotoLibrarySelection] {
        var selections: [PhotoLibrarySelection] = []
        for index in 0..<count {
            let name = "photo-\(index).jpg"
            let url = directory.appendingPathComponent(name)
            try Benchmark.photoJPEG(width: width, height: height, seed: UInt64(index + 1)).write(to: url)
            selections.append(PhotoLibrarySelection(
                itemProvider: try XCTUnwrap(NSItemProvider(contentsOf: url)),
                typeIdentifier: "public.jpeg",
                mediaType: .photo,
                originalFilename: name,
                deletionCheck: deletionCheck(index)
            ))
        }
        return selections
    }

    private func waitUntilPrepared(_ viewModel: ImportViewModel) async throws {
        for _ in 0..<1_000 where viewModel.isPreparing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isPreparing, "Preparation did not finish")
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
        _ = try XCTUnwrap(viewModel.candidates.first, "The photo was not prepared.")
        return viewModel
    }

    /// Holds the main thread, as a long render would, until the importer has reported everything or 20 seconds pass.
    /// The importer starts reporting only once the main thread is held.
    private func blockMainThread(whileReporting importer: ProgressReportingImporter) -> Bool {
        importer.mainThreadHeld.signal()
        return importer.finishedReporting.wait(timeout: .now() + 20) == .success
    }
}

private actor DelayedMetadataReader: MediaMetadataReading {
    private let delays: [TimeInterval]
    private let failingIndices: Set<Int>
    private var activeReads = 0
    private(set) var maximumConcurrentReads = 0

    init(delays: [TimeInterval], failingIndices: Set<Int> = []) {
        self.delays = delays
        self.failingIndices = failingIndices
    }

    func metadata(for url: URL, mediaType: MediaType, originalFilename: String?) async throws -> MediaMetadata {
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        let index = Int(originalFilename?.filter(\.isNumber) ?? "") ?? 0
        try await Task.sleep(nanoseconds: UInt64(delays[index % delays.count] * 1_000_000_000))
        guard !failingIndices.contains(index) else { throw VaultError.unsupportedFileType }
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

/// Imports every source at once, consuming its incoming copy.
private actor CompletingImporter: MediaImporting {
    func importMedia(
        _ sources: [ImportSource],
        albumID: UUID?,
        preflightFailureCount: Int,
        preflightThumbnailFailureCount: Int,
        progress: (@Sendable (ImportProgress) async -> Void)?
    ) async throws -> ImportSummary {
        sources.forEach { IncomingMediaFileStore.remove($0.temporaryURL) }
        var summary = ImportSummary()
        summary.importedCount = sources.count
        return summary
    }

    func cleanupAbandonedIncomingFiles() async {}

    func cancelAllOperations() async {}
}

private actor IdlePhotoLibrary: PhotoLibraryServing {
    func requestImportAccess() async -> PhotoLibraryImportAccess {
        .full
    }

    func deleteOriginals(localIdentifiers: [String]) async throws {}

    func sourceIdentifiers(for checks: [PhotoLibraryDeletionCheck]) async -> [String?] {
        checks.map { _ -> String? in nil }
    }
}

/// Answers deletion checks with fixed identifiers and records every request.
private actor RecordingPhotoLibrary: PhotoLibraryServing {
    private let answers: [String?]
    private(set) var requests: [[PhotoLibraryDeletionCheck]] = []

    init(answers: [String?]) {
        self.answers = answers
    }

    func requestImportAccess() async -> PhotoLibraryImportAccess {
        .full
    }

    func deleteOriginals(localIdentifiers: [String]) async throws {}

    func sourceIdentifiers(for checks: [PhotoLibraryDeletionCheck]) async -> [String?] {
        requests.append(checks)
        return answers
    }
}

/// Reports a run of progress values from off the main thread, then succeeds. It reports only while the test holds the
/// main thread, so any report that waits for the main thread stalls until the test gives up.
private final class ProgressReportingImporter: MediaImporting, @unchecked Sendable {
    let started = XCTestExpectation(description: "The import started")
    let mainThreadHeld = DispatchSemaphore(value: 0)
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
        waitUntilTheMainThreadIsHeld()
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

    private func waitUntilTheMainThreadIsHeld() {
        _ = mainThreadHeld.wait(timeout: .now() + 30)
    }
}
