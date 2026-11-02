import UIKit
import XCTest
@testable import QuietFrame

@MainActor
final class ImportPreviewImagesTests: XCTestCase {
    /// A 4:3 camera photo's metadata; its stored preview is 720x540.
    private let cameraMetadata = Benchmark.metadata(filename: "IMG_0001.JPG", width: 4_032, height: 3_024, byteCount: 1_000)

    func testPreviewIsDecodedAtTheTileSizeAndNeverAboveTheStoredSize() throws {
        let candidate = makeCandidate(thumbnail: storedPreview(seed: 1))
        let iPhoneTile = ImportPreviewImages.pixelSize(tileWidth: 114, scale: 3, metadata: cameraMetadata)
        let accessibilityTile = ImportPreviewImages.pixelSize(tileWidth: 240, scale: 3, metadata: cameraMetadata)

        let small = try XCTUnwrap(ImportPreviewImages().image(for: candidate, pixelSize: iPhoneTile)?.cgImage)
        let large = try XCTUnwrap(ImportPreviewImages().image(for: candidate, pixelSize: accessibilityTile)?.cgImage)

        XCTAssertEqual(iPhoneTile, 512)
        XCTAssertEqual(small.width, 512)
        XCTAssertEqual(small.height, 384)
        XCTAssertEqual(accessibilityTile, ThumbnailService.storedPixelSize)
        XCTAssertEqual(large.width, 720)
        XCTAssertEqual(large.height, 540)
    }

    func testUnknownMediaSizeDecodesTheWholeStoredPreview() {
        let unknown = Benchmark.metadata(filename: "IMG_0002.JPG", width: 0, height: 0, byteCount: 1_000)

        XCTAssertEqual(ImportPreviewImages.pixelSize(tileWidth: 114, scale: 3, metadata: unknown), ThumbnailService.storedPixelSize)
    }

    func testATileGetsItsPreviewEvenWhenNothingIsCached() throws {
        let previews = ImportPreviewImages()
        let candidate = makeCandidate(thumbnail: storedPreview(seed: 2))

        let first = try XCTUnwrap(previews.image(for: candidate, pixelSize: 512))
        let second = previews.image(for: candidate, pixelSize: 512)

        XCTAssertTrue(first === second)
        XCTAssertTrue(previews.cachedImage(for: candidate.id, atLeast: 512) === first)
        XCTAssertEqual(previews.decodeCount, 1)
    }

    func testALargerCachedPreviewServesSmallerTilesAndASmallerOneIsReplaced() throws {
        let previews = ImportPreviewImages()
        let large = makeCandidate(thumbnail: storedPreview(seed: 3))
        let small = makeCandidate(thumbnail: storedPreview(seed: 4))

        let largeImage = try XCTUnwrap(previews.image(for: large, pixelSize: 720))
        XCTAssertTrue(previews.image(for: large, pixelSize: 512) === largeImage)
        XCTAssertEqual(previews.decodeCount, 1)

        let smallImage = try XCTUnwrap(previews.image(for: small, pixelSize: 448))
        let replacement = try XCTUnwrap(previews.image(for: small, pixelSize: 512))
        XCTAssertFalse(smallImage === replacement)
        XCTAssertEqual(replacement.cgImage?.width, 512)
        XCTAssertTrue(previews.cachedImage(for: small.id, atLeast: 512) === replacement)
        XCTAssertEqual(previews.decodeCount, 3)
    }

    func testItemsWithoutAPreviewKeepThePlaceholder() {
        let previews = ImportPreviewImages()
        let missing = makeCandidate(thumbnail: nil)
        let corrupt = makeCandidate(thumbnail: Data("not a jpeg".utf8))

        XCTAssertNil(previews.image(for: missing, pixelSize: 512))
        XCTAssertEqual(previews.decodeCount, 0)
        XCTAssertNil(previews.image(for: corrupt, pixelSize: 512))
        XCTAssertNil(previews.image(for: corrupt, pixelSize: 512))
        XCTAssertEqual(previews.decodeCount, 1)
    }

    func testLoadingCachesPreviewsBeforeReturning() async {
        let previews = ImportPreviewImages()
        let candidates = (0..<4).map { makeCandidate(thumbnail: storedPreview(seed: UInt64(10 + $0))) }

        await previews.load(candidates, tileWidth: 114, scale: 3)

        for candidate in candidates {
            XCTAssertEqual(previews.cachedImage(for: candidate.id, atLeast: 512)?.cgImage?.width, 512)
        }
        XCTAssertEqual(previews.decodeCount, 4)
    }

    func testRemoveAllDropsPreviewsAndIgnoresDecodesStillRunning() async throws {
        let previews = ImportPreviewImages()
        let candidates = (0..<10).map { makeCandidate(thumbnail: storedPreview(seed: UInt64(20 + $0))) }

        previews.prefetch(candidates, tileWidth: 114, scale: 3)
        previews.removeAll()
        try await Task.sleep(nanoseconds: 500_000_000)

        for candidate in candidates {
            XCTAssertNil(previews.cachedImage(for: candidate.id, atLeast: 1))
        }
    }

    func testRemovingOnePreviewKeepsTheOthers() throws {
        let previews = ImportPreviewImages()
        let kept = makeCandidate(thumbnail: storedPreview(seed: 30))
        let removed = makeCandidate(thumbnail: storedPreview(seed: 31))
        _ = try XCTUnwrap(previews.image(for: kept, pixelSize: 512))
        _ = try XCTUnwrap(previews.image(for: removed, pixelSize: 512))

        previews.remove(removed.id)

        XCTAssertNotNil(previews.cachedImage(for: kept.id, atLeast: 512))
        XCTAssertNil(previews.cachedImage(for: removed.id, atLeast: 1))
    }

    /// The thumbnail import stores for a 4:3 photo: 720x540 at JPEG quality 0.82.
    private func storedPreview(seed: UInt64) -> Data {
        Benchmark.photoJPEG(width: 720, height: 540, seed: seed, quality: 0.82)
    }

    private func makeCandidate(thumbnail: Data?) -> ImportPreviewCandidate {
        ImportPreviewCandidate(
            source: ImportSource(
                temporaryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                metadata: cameraMetadata,
                thumbnailJPEGData: thumbnail,
                sourceLocalIdentifier: nil
            ),
            thumbnailFailed: thumbnail == nil
        )
    }
}
