import XCTest
@testable import QuietFrame

/// Passcode key derivation and the encrypted container's hot paths, measured through the storage API the app uses.
@MainActor
final class CryptoBenchmarks: XCTestCase {
    func testPasscodeKeyDerivation() {
        let passcode = Data("482916".utf8)
        let salt = Benchmark.randomData(byteCount: 16, seed: 1)
        let iterations = AuthenticationService.Policy.production.derivationIterations

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            do {
                _ = try PBKDF2.deriveSHA256Key(password: passcode, salt: salt, iterations: iterations)
            } catch {
                XCTFail("Key derivation failed: \(error)")
            }
        }
    }

    func testEncryptingAThirtyTwoMegabyteFile() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let source = try vault.writeSource(Benchmark.randomData(byteCount: 32 * 1_048_576, seed: 2), named: "video.mov")

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                _ = try await vault.storage.store(plaintextURL: source, location: .media, progress: nil)
            }
        }
    }

    /// Import progress reaches the main actor during encryption, the way the import screen shows it. While the main
    /// thread is busy drawing, any wait for it lands on the encryption path.
    func testEncryptingWhileTheMainThreadIsBusy() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let source = try vault.writeSource(Benchmark.randomData(byteCount: 32 * 1_048_576, seed: 3), named: "video.mov")

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            let busyMainThread = Timer(timeInterval: 0.008, repeats: true) { _ in
                _ = usleep(4_000)
            }
            RunLoop.main.add(busyMainThread, forMode: .common)
            runBenchmark {
                let progress = LatestValueRelay<Double> { _ = $0 }
                _ = try await vault.storage.store(plaintextURL: source, location: .media) { fraction in
                    progress.send(fraction)
                }
                await progress.finish()
            }
            busyMainThread.invalidate()
        }
    }

    func testDecryptingSixtyThumbnails() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let identifiers: [String] = try awaitBenchmark {
            var identifiers: [String] = []
            for index in 0..<60 {
                let data = Benchmark.randomData(byteCount: 60_000, seed: UInt64(100 + index))
                identifiers.append(try await vault.store(data, location: .thumbnails))
            }
            return identifiers
        }

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                for identifier in identifiers {
                    _ = try await vault.storage.decryptData(
                        identifier: identifier,
                        location: .thumbnails,
                        maximumByteCount: 16 * 1_048_576
                    )
                }
            }
        }
    }

    /// The wait before streaming playback has its first bytes: opening the container and decrypting its first chunk.
    func testOpeningAFortyEightMegabyteVideoStream() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let identifier = try awaitBenchmark {
            try await vault.store(Benchmark.randomData(byteCount: 48 * 1_048_576, seed: 4), location: .media)
        }

        measure(metrics: [XCTClockMetric()], options: Benchmark.options) {
            runBenchmark {
                let reader = try await vault.storage.openEncryptedReader(identifier: identifier, location: .media)
                let firstBytes = try await reader.read(offset: 0, length: 65_536)
                XCTAssertEqual(firstBytes.count, 65_536)
                await reader.close()
            }
        }
    }

    /// The wait between opening a video and having something AVFoundation can play, before playback streamed.
    func testPreparingAFortyEightMegabyteVideoForPlayback() throws {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        defer { vault.remove() }
        let identifier = try awaitBenchmark {
            try await vault.store(Benchmark.randomData(byteCount: 48 * 1_048_576, seed: 4), location: .media)
        }

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            let box = BenchmarkResultBox<SecureTemporaryFileLease>()
            startMeasuring()
            runBenchmark {
                box.result = .success(try await vault.storage.temporaryDecryptedFile(
                    identifier: identifier,
                    location: .media,
                    preferredExtension: "mov"
                ))
            }
            stopMeasuring()
            if case .success(let lease)? = box.result {
                lease.cleanup()
            }
        }
    }
}
