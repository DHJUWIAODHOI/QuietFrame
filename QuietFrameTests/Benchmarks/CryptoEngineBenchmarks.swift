import XCTest
@testable import QuietFrame

/// The crypto engine under concurrent load, measured through the storage API the app uses: a page of thumbnails
/// requested together, thumbnails read while Share decrypts a large item, and a large photo decrypted into memory.
@MainActor
final class CryptoEngineBenchmarks: XCTestCase {
    private let thumbnailByteCount = 60_000
    private let thumbnailByteLimit = 16 * 1_048_576

    /// A page of grid tiles starts its thumbnail loads together.
    func testDecryptingSixtyThumbnailsAtOnce() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let identifiers = try storeThumbnails(count: 60, in: vault)
        let storage = vault.storage
        let byteLimit = thumbnailByteLimit
        let expectedByteCount = identifiers.count * thumbnailByteCount

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                let byteCount = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
                    for identifier in identifiers {
                        group.addTask {
                            let thumbnail = try await storage.decryptData(
                                identifier: identifier,
                                location: .thumbnails,
                                maximumByteCount: byteLimit
                            )
                            return thumbnail.count
                        }
                    }
                    var total = 0
                    for try await count in group {
                        total += count
                    }
                    return total
                }
                XCTAssertEqual(byteCount, expectedByteCount)
            }
        }
    }

    /// Share decrypts a 128 MiB video to a temporary file while the grid reads thirty thumbnails one after another.
    func testDecryptingThumbnailsWhileALargeItemDecryptsForSharing() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let thumbnails = try storeThumbnails(count: 30, in: vault)
        let video = try awaitBenchmark {
            try await vault.store(Benchmark.randomData(byteCount: 128 * 1_048_576, seed: 50), location: .media)
        }
        let storage = vault.storage
        let byteLimit = thumbnailByteLimit
        let temporaryDirectory = vault.directory
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("QuietFrameTemporary", isDirectory: true)

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let sharing = Task.detached {
                let lease = try await storage.temporaryDecryptedFile(
                    identifier: video,
                    location: .media,
                    preferredExtension: "mov"
                )
                lease.cleanup()
            }
            runBenchmark {
                var attempts = 0
                while attempts < 2_000, !CryptoEngineBenchmarks.containsFiles(temporaryDirectory) {
                    attempts += 1
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            startMeasuring()
            runBenchmark {
                for identifier in thumbnails {
                    _ = try await storage.decryptData(
                        identifier: identifier,
                        location: .thumbnails,
                        maximumByteCount: byteLimit
                    )
                }
            }
            stopMeasuring()
            runBenchmark {
                try await sharing.value
            }
        }
    }

    /// The viewer decrypts a whole photo into memory before decoding it; 24 MiB is a large 48 MP photo.
    func testDecryptingATwentyFourMegabytePhotoIntoMemory() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let byteCount = 24 * 1_048_576
        let identifier = try awaitBenchmark {
            try await vault.store(Benchmark.randomData(byteCount: byteCount, seed: 51), location: .media)
        }
        let storage = vault.storage

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: Benchmark.options) {
            runBenchmark {
                let photo = try await storage.decryptData(
                    identifier: identifier,
                    location: .media,
                    maximumByteCount: 512 * 1_048_576
                )
                XCTAssertEqual(photo.count, byteCount)
            }
        }
    }

    /// Thumbnails as import stores them, encrypted from memory.
    private func storeThumbnails(count: Int, in vault: BenchmarkVault) throws -> [String] {
        let byteCount = thumbnailByteCount
        let identifiers: [String] = try awaitBenchmark {
            var identifiers: [String] = []
            for index in 0..<count {
                let thumbnail = Benchmark.randomData(byteCount: byteCount, seed: UInt64(300 + index))
                let stored = try await vault.storage.store(plaintextData: thumbnail, location: .thumbnails)
                identifiers.append(stored.identifier)
            }
            return identifiers
        }
        return identifiers
    }

    private static func containsFiles(_ directory: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return !contents.isEmpty
    }
}
