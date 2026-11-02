import SwiftData
import UIKit
import XCTest
@testable import QuietFrame

/// The gallery's thumbnail path: decrypt, decode and draw. Drawing each image into a tile-sized bitmap on the main
/// actor stands in for the work Core Animation does on the main thread the first time a tile shows an image.
@MainActor
final class ThumbnailBenchmarks: XCTestCase {
    /// An iPhone 16 Pro tile at the default (Comfortable) size, in pixels.
    private let tilePixelSide: CGFloat = 342
    /// The decode size the grid asks for when a 4:3 photo fills that tile.
    private let gridPixelSize = ThumbnailService.pixelSize(
        fillingSquareOf: 114,
        scale: 3,
        mediaPixelSize: CGSize(width: 4_032, height: 3_024)
    )

    func testAPageOfThumbnailsReachesTheScreen() throws {
        let fixture = try makeFixture(thumbnailCount: 48)
        defer { fixture.remove() }

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            fixture.service.clearCache()
            startMeasuring()
            runBenchmark {
                let images = await self.loadConcurrently(fixture.media, service: fixture.service)
                XCTAssertEqual(images.count, fixture.media.count)
                images.forEach(self.drawTile)
            }
            stopMeasuring()
        }
    }

    func testDrawingAPageOfLoadedThumbnailsOnTheMainThread() throws {
        let fixture = try makeFixture(thumbnailCount: 48)
        defer { fixture.remove() }

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            fixture.service.clearCache()
            let box = BenchmarkResultBox<[UIImage]>()
            runBenchmark {
                box.result = .success(await self.loadConcurrently(fixture.media, service: fixture.service))
            }
            guard case .success(let images)? = box.result else { return }
            XCTAssertEqual(images.count, fixture.media.count)
            startMeasuring()
            images.forEach(drawTile)
            stopMeasuring()
        }
    }

    /// The same page at the size the grid requests for its tiles.
    func testAPageOfGridSizedThumbnailsReachesTheScreen() throws {
        let fixture = try makeFixture(thumbnailCount: 48)
        defer { fixture.remove() }
        let pixelSize = gridPixelSize

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            fixture.service.clearCache()
            startMeasuring()
            runBenchmark {
                let images = await self.loadConcurrently(fixture.media, service: fixture.service, pixelSize: pixelSize)
                XCTAssertEqual(images.count, fixture.media.count)
                images.forEach(self.drawTile)
            }
            stopMeasuring()
        }
    }

    /// Scrolls through 160 grid-sized thumbnails, then back to the first 48.
    func testScrollingBackToEarlierGridSizedThumbnails() throws {
        let fixture = try makeFixture(thumbnailCount: 160)
        defer { fixture.remove() }
        let firstScreen = Array(fixture.media.prefix(48))
        let pixelSize = gridPixelSize

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            fixture.service.clearCache()
            runBenchmark {
                for page in stride(from: 0, to: fixture.media.count, by: 24) {
                    let slice = Array(fixture.media[page..<min(page + 24, fixture.media.count)])
                    _ = await self.loadConcurrently(slice, service: fixture.service, pixelSize: pixelSize)
                }
            }
            startMeasuring()
            runBenchmark {
                let images = await self.loadConcurrently(firstScreen, service: fixture.service, pixelSize: pixelSize)
                XCTAssertEqual(images.count, firstScreen.count)
                images.forEach(self.drawTile)
            }
            stopMeasuring()
        }
    }

    /// Scrolls through 160 thumbnails, then back to the first 48.
    func testScrollingBackToEarlierThumbnails() throws {
        let fixture = try makeFixture(thumbnailCount: 160)
        defer { fixture.remove() }
        let firstScreen = Array(fixture.media.prefix(48))

        measure(metrics: [XCTClockMetric()], options: Benchmark.manualOptions) {
            fixture.service.clearCache()
            runBenchmark {
                for page in stride(from: 0, to: fixture.media.count, by: 24) {
                    let slice = Array(fixture.media[page..<min(page + 24, fixture.media.count)])
                    _ = await self.loadConcurrently(slice, service: fixture.service)
                }
            }
            startMeasuring()
            runBenchmark {
                let images = await self.loadConcurrently(firstScreen, service: fixture.service)
                XCTAssertEqual(images.count, firstScreen.count)
                images.forEach(self.drawTile)
            }
            stopMeasuring()
        }
    }

    @MainActor
    private struct Fixture {
        let vault: BenchmarkVault
        let library: BenchmarkLibrary
        let service: ThumbnailService
        let media: [VaultMedia]

        func remove() {
            library.remove()
            vault.remove()
        }
    }

    /// Thumbnails as import stores them today: 720-pixel JPEGs at quality 0.82, one per item.
    private func makeFixture(thumbnailCount: Int) throws -> Fixture {
        let vault = try awaitBenchmark { try await BenchmarkVault.make() }
        let identifiers: [String] = try awaitBenchmark {
            var identifiers: [String] = []
            for index in 0..<thumbnailCount {
                let jpeg = Benchmark.photoJPEG(width: 720, height: 540, seed: UInt64(1_000 + index), quality: 0.82)
                identifiers.append(try await vault.store(jpeg, location: .thumbnails))
            }
            return identifiers
        }
        let library = try BenchmarkLibrary.make(itemCount: thumbnailCount, thumbnailIdentifiers: identifiers)
        let media = try library.context.fetch(FetchDescriptor<VaultMedia>(
            sortBy: [SortDescriptor(\VaultMedia.importedAt, order: .forward)]
        ))
        return Fixture(
            vault: vault,
            library: library,
            service: ThumbnailService(storage: vault.storage),
            media: media
        )
    }

    /// Requests every thumbnail at once, the way a page of grid tiles starts its tasks together.
    private func loadConcurrently(
        _ media: [VaultMedia],
        service: ThumbnailService,
        pixelSize: Int = ThumbnailService.storedPixelSize
    ) async -> [UIImage] {
        await withTaskGroup(of: UIImage?.self, returning: [UIImage].self) { group in
            for item in media {
                group.addTask { @MainActor in
                    await service.image(for: item, pixelSize: pixelSize)
                }
            }
            var images: [UIImage] = []
            for await image in group {
                if let image {
                    images.append(image)
                }
            }
            return images
        }
    }

    private func drawTile(_ image: UIImage) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side = tilePixelSide
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        _ = renderer.image { _ in
            let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        }
    }
}
