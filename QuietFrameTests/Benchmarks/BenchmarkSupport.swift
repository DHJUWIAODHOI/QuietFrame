import SwiftData
import UIKit
import XCTest
@testable import QuietFrame

/// Shared fixtures for the performance benchmarks. Everything lives in fresh temporary directories and in-test
/// containers; nothing reads or writes the app's real vault, store or Keychain.
enum Benchmark {
    static let iterationCount = 5

    static var options: XCTMeasureOptions {
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = iterationCount
        return measureOptions
    }

    /// For blocks that set up each iteration before calling `startMeasuring()`.
    static var manualOptions: XCTMeasureOptions {
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = iterationCount
        measureOptions.invocationOptions = [.manuallyStart, .manuallyStop]
        return measureOptions
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuietFrameBenchmarks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Bytes that do not compress, so file sizes and crypto work match real media.
    static func randomData(byteCount: Int, seed: UInt64) -> Data {
        var generator = SeededGenerator(seed: seed)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var index = 0
        while index < byteCount {
            var word = generator.next()
            for _ in 0..<8 where index < byteCount {
                bytes[index] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                index += 1
            }
        }
        return Data(bytes)
    }

    /// A photo-like JPEG: a gradient under many overlapping shapes, so decoding costs about what a camera image does.
    static func photoJPEG(width: Int, height: Int, seed: UInt64, quality: CGFloat = 0.85) -> Data {
        var generator = SeededGenerator(seed: seed)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { context in
            let startColor = generator.color()
            let endColor = generator.color()
            let colors = [startColor.cgColor, endColor.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            let shapeCount = max(200, width * height / 20_000)
            for _ in 0..<shapeCount {
                let x = generator.unit() * size.width
                let y = generator.unit() * size.height
                let shapeWidth = 4 + generator.unit() * size.width / 12
                let shapeHeight = 4 + generator.unit() * size.height / 12
                let alpha = 0.35 + generator.unit() * 0.5
                let fill = generator.color(alpha: alpha)
                let rect = CGRect(x: x, y: y, width: shapeWidth, height: shapeHeight)
                context.cgContext.setFillColor(fill.cgColor)
                if generator.next() % 2 == 0 {
                    context.cgContext.fillEllipse(in: rect)
                } else {
                    context.cgContext.fill(rect)
                }
            }
        }
    }

    static func metadata(
        filename: String,
        width: Int,
        height: Int,
        byteCount: Int64,
        mediaType: MediaType = .photo
    ) -> MediaMetadata {
        MediaMetadata(
            mediaType: mediaType,
            contentTypeIdentifier: mediaType == .video ? "com.apple.quicktime-movie" : "public.jpeg",
            originalFilename: filename,
            originalCreationDate: nil,
            pixelWidth: width,
            pixelHeight: height,
            duration: mediaType == .video ? 12 : nil,
            byteCount: byteCount
        )
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / 9_007_199_254_740_992
    }

    mutating func color(alpha: CGFloat = 1) -> UIColor {
        let red = unit()
        let green = unit()
        let blue = unit()
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// A real session and encrypted storage in temporary directories, with the production chunk size.
struct BenchmarkVault {
    let directory: URL
    let session: VaultSession
    let storage: SecureFileStorageService

    static func make() async throws -> BenchmarkVault {
        let directory = try Benchmark.temporaryDirectory()
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x5A, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session),
            baseURL: directory.appendingPathComponent("ApplicationSupport", isDirectory: true),
            temporaryBaseURL: directory.appendingPathComponent("Caches", isDirectory: true),
            applyFileProtection: false
        )
        return BenchmarkVault(directory: directory, session: session, storage: storage)
    }

    func writeSource(_ data: Data, named name: String) throws -> URL {
        let sources = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let url = sources.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func store(_ data: Data, location: EncryptedAssetLocation) async throws -> String {
        let url = try writeSource(data, named: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await storage.store(plaintextURL: url, location: location, progress: nil).identifier
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A library in an on-disk store opened the way the app opens it (latest schema plus the migration plan).
@MainActor
struct BenchmarkLibrary {
    static let albumCount = 20

    let directory: URL
    let container: ModelContainer
    let albums: [VaultAlbum]

    var context: ModelContext {
        container.mainContext
    }

    /// `itemCount` items imported ten minutes apart: about 70% in one of 20 albums, every 10th a video,
    /// every 20th a favorite and every 33rd moved to the Trash in the last few hours, so none has expired.
    /// `thumbnailIdentifiers` are assigned in turn.
    static func make(itemCount: Int, thumbnailIdentifiers: [String] = []) throws -> BenchmarkLibrary {
        let directory = try Benchmark.temporaryDirectory()
        let schema = Schema(versionedSchema: VaultSchemaV3.self)
        let configuration = ModelConfiguration(
            "Benchmark",
            schema: schema,
            url: directory.appendingPathComponent("Benchmark.store")
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: VaultMigrationPlan.self,
            configurations: [configuration]
        )
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date()
        let albums = (0..<albumCount).map { index in
            VaultAlbum(name: "Album \(index + 1)", createdAt: start, position: index)
        }
        for album in albums {
            context.insert(album)
        }

        for index in 0..<itemCount {
            let isVideo = index % 10 == 0
            let isTrashed = index % 33 == 0
            let homeAlbum = index % 10 < 7 ? albums[index % albumCount] : nil
            let thumbnailIdentifier = thumbnailIdentifiers.isEmpty
                ? UUID().uuidString.lowercased()
                : thumbnailIdentifiers[index % thumbnailIdentifiers.count]
            let media = VaultMedia(
                storageIdentifier: UUID().uuidString.lowercased(),
                contentFingerprint: String(format: "%064lx", index),
                thumbnailIdentifier: thumbnailIdentifier,
                metadata: Benchmark.metadata(
                    filename: String(format: isVideo ? "IMG_%04ld.MOV" : "IMG_%04ld.JPG", index),
                    width: 4_032,
                    height: 3_024,
                    byteCount: Int64(2_000_000 + index * 37),
                    mediaType: isVideo ? .video : .photo
                ),
                importedAt: start.addingTimeInterval(TimeInterval(index * 600)),
                isFavorite: index % 20 == 0,
                album: isTrashed ? nil : homeAlbum
            )
            if isTrashed {
                media.trashedAt = now.addingTimeInterval(-TimeInterval(index))
                media.previousAlbumID = homeAlbum?.id
            }
            context.insert(media)
            if index % 1_000 == 999 {
                try context.save()
            }
        }
        try context.save()
        return BenchmarkLibrary(directory: directory, container: container, albums: albums)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

final class BenchmarkResultBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

enum BenchmarkError: Error {
    case timedOut
    case missingResult
}

extension XCTestCase {
    /// Runs async work to completion from a synchronous test or `measure` block. XCTest's wait spins the main run
    /// loop, so main-actor work inside the task keeps running.
    @MainActor
    func awaitBenchmark<Value>(
        timeout: TimeInterval = 180,
        _ operation: @escaping @MainActor () async throws -> Value
    ) throws -> Value {
        let box = BenchmarkResultBox<Value>()
        let finished = expectation(description: "Benchmark work finished")
        Task { @MainActor in
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: timeout)
        guard let result = box.result else { throw BenchmarkError.timedOut }
        return try result.get()
    }

    /// The non-throwing form for `measure` blocks: a failure is recorded and the iteration ends.
    @MainActor
    func runBenchmark(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        do {
            try awaitBenchmark(operation)
        } catch {
            XCTFail("Benchmark iteration failed: \(error)", file: file, line: line)
        }
    }
}
