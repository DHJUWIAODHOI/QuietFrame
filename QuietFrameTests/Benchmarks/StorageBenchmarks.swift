import SwiftData
import XCTest
@testable import QuietFrame

/// Storage work against real files in the vault's directory layout: the analysis behind Settings > Storage, bulk
/// moves between media and trash, and Empty Trash. Each "one call each" or "one file at a time" benchmark repeats
/// the previous way on the same data, so one run compares the two.
@MainActor
final class StorageBenchmarks: XCTestCase {
    private let itemCount = 5_000
    private let fileCount = 1_000

    func testAnalyzingStorageUsage() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        try createPlaceholderFiles(for: library, in: vault)
        let service = StorageAnalysisService(modelContext: library.context, storage: vault.storage)
        let expected = try awaitBenchmark {
            try await PerFileStorageAnalysis.summary(context: library.context, storage: vault.storage)
        }
        let analyzed = try awaitBenchmark { try await service.analyze() }
        XCTAssertEqual(analyzed, expected)

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                let summary = try await service.analyze()
                XCTAssertEqual(summary.totalEncryptedBytes, expected.totalEncryptedBytes)
            }
        }
    }

    /// The analysis as it was: one size call per original and per thumbnail, and the largest items sorted over the
    /// models.
    func testAnalyzingStorageUsageOneFileAtATime() throws {
        let library = try BenchmarkLibrary.make(itemCount: itemCount)
        defer { library.remove() }
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        try createPlaceholderFiles(for: library, in: vault)
        let service = StorageAnalysisService(modelContext: library.context, storage: vault.storage)
        let expected = try awaitBenchmark { try await service.analyze() }

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                let summary = try await PerFileStorageAnalysis.summary(context: library.context, storage: vault.storage)
                XCTAssertEqual(summary, expected)
            }
        }
    }

    /// Moving to the Trash as it was: one main-to-storage round trip per file.
    func testMovingAThousandFilesOneCallEach() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let identifiers = try placeMediaFiles(count: fileCount, in: vault)
        let storage = vault.storage

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            startMeasuring()
            runBenchmark {
                for identifier in identifiers {
                    try await storage.move(identifier: identifier, from: .media, to: .trash)
                }
            }
            stopMeasuring()
            runBenchmark {
                let movedBack = await storage.move(identifiers: identifiers, from: .trash, to: .media)
                XCTAssertNil(movedBack.failure)
            }
        }
    }

    func testMovingAThousandFilesInOneBatch() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let identifiers = try placeMediaFiles(count: fileCount, in: vault)
        let storage = vault.storage

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            startMeasuring()
            runBenchmark {
                let moved = await storage.move(identifiers: identifiers, from: .media, to: .trash)
                XCTAssertNil(moved.failure)
            }
            stopMeasuring()
            runBenchmark {
                let movedBack = await storage.move(identifiers: identifiers, from: .trash, to: .media)
                XCTAssertNil(movedBack.failure)
            }
        }
    }

    /// A thousand trashed items, each with its original and thumbnail, refilled before every iteration.
    func testEmptyingAThousandItemTrash() throws {
        let library = try BenchmarkLibrary.make(itemCount: 0)
        defer { library.remove() }
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let service = TrashService(modelContext: library.context, storage: vault.storage)
        let count = fileCount

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            do {
                try fillTrash(count: count, in: library, vault: vault)
            } catch {
                XCTFail("Could not fill the Trash: \(error)")
                return
            }
            startMeasuring()
            runBenchmark {
                let emptied = try await service.emptyTrash()
                XCTAssertEqual(emptied.deletedCount, count)
            }
            stopMeasuring()
        }
    }

    /// Files of different sizes, so every total depends on every file.
    private func createPlaceholderFiles(for library: BenchmarkLibrary, in vault: BenchmarkVault) throws {
        for (index, media) in try library.context.fetch(FetchDescriptor<VaultMedia>()).enumerated() {
            let location: EncryptedAssetLocation = media.isTrashed ? .trash : .media
            try writePlaceholder(media.storageIdentifier, in: location, of: vault, byteCount: 64 + index % 512)
            if let thumbnailIdentifier = media.thumbnailIdentifier {
                try writePlaceholder(thumbnailIdentifier, in: .thumbnails, of: vault, byteCount: 16 + index % 128)
            }
        }
    }

    private func placeMediaFiles(count: Int, in vault: BenchmarkVault) throws -> [String] {
        var identifiers: [String] = []
        identifiers.reserveCapacity(count)
        for _ in 0..<count {
            let identifier = UUID().uuidString.lowercased()
            try writePlaceholder(identifier, in: .media, of: vault, byteCount: 64)
            identifiers.append(identifier)
        }
        return identifiers
    }

    private func fillTrash(count: Int, in library: BenchmarkLibrary, vault: BenchmarkVault) throws {
        let trashedAt = Date()
        for index in 0..<count {
            let storageIdentifier = UUID().uuidString.lowercased()
            let thumbnailIdentifier = UUID().uuidString.lowercased()
            let media = VaultMedia(
                storageIdentifier: storageIdentifier,
                contentFingerprint: UUID().uuidString,
                thumbnailIdentifier: thumbnailIdentifier,
                metadata: Benchmark.metadata(
                    filename: String(format: "IMG_%04ld.JPG", index),
                    width: 4_032,
                    height: 3_024,
                    byteCount: 2_000_000
                )
            )
            media.trashedAt = trashedAt
            library.context.insert(media)
            try writePlaceholder(storageIdentifier, in: .trash, of: vault, byteCount: 64)
            try writePlaceholder(thumbnailIdentifier, in: .thumbnails, of: vault, byteCount: 16)
        }
        try library.context.save()
    }

    private func writePlaceholder(
        _ identifier: String,
        in location: EncryptedAssetLocation,
        of vault: BenchmarkVault,
        byteCount: Int
    ) throws {
        let url = vault.directory
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent("QuietFrameVault", isDirectory: true)
            .appendingPathComponent(location.rawValue, isDirectory: true)
            .appendingPathComponent("\(identifier).qfe", isDirectory: false)
        try Data(count: byteCount).write(to: url)
    }
}
