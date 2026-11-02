import SwiftData
import UIKit
import XCTest
@testable import QuietFrame

@MainActor
final class ThumbnailServiceTests: XCTestCase {
    func testDecodesNoLargerThanTheRequestedSize() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)

        let loaded = await fixture.service.image(for: fixture.media[0], pixelSize: 256)
        let cgImage = try XCTUnwrap(loaded?.cgImage)

        XCTAssertEqual(cgImage.width, 256)
        XCTAssertEqual(cgImage.height, 192)
    }

    func testStoredSizeKeepsFullResolution() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)

        let loaded = await fixture.service.image(for: fixture.media[0])
        let cgImage = try XCTUnwrap(loaded?.cgImage)

        XCTAssertEqual(cgImage.width, 720)
        XCTAssertEqual(cgImage.height, 540)
    }

    func testConcurrentRequestsShareOneDecrypt() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)
        let service = fixture.service
        let media = fixture.media[0]
        await fixture.storage.holdDecrypts()

        let first = Task { await service.image(for: media, pixelSize: 384) }
        let second = Task { await service.image(for: media, pixelSize: 384) }
        try await waitUntil { await fixture.storage.heldDecryptCount == 1 }
        await fixture.storage.releaseDecrypts()
        let firstLoaded = await first.value
        let secondLoaded = await second.value

        let firstImage = try XCTUnwrap(firstLoaded)
        XCTAssertTrue(firstImage === secondLoaded)
        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 1)
    }

    func testCachedImageIsReturnedWithoutDecryptingAgain() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)

        let first = await fixture.service.image(for: fixture.media[0], pixelSize: 384)
        let second = await fixture.service.image(for: fixture.media[0], pixelSize: 384)

        let image = try XCTUnwrap(first)
        XCTAssertTrue(image === second)
        XCTAssertTrue(fixture.service.cachedImage(for: fixture.media[0], pixelSize: 384) === image)
        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 1)
    }

    func testLargerCachedImageServesSmallerRequests() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)

        let large = await fixture.service.image(for: fixture.media[0], pixelSize: 512)
        let small = await fixture.service.image(for: fixture.media[0], pixelSize: 256)

        let image = try XCTUnwrap(large)
        XCTAssertTrue(image === small)
        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 1)
    }

    func testSmallerCachedImageDoesNotServeLargerRequests() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)

        let small = await fixture.service.image(for: fixture.media[0], pixelSize: 256)
        XCTAssertNil(fixture.service.cachedImage(for: fixture.media[0], pixelSize: 720))
        let large = await fixture.service.image(for: fixture.media[0])

        let largeImage = try XCTUnwrap(large)
        XCTAssertNotNil(small)
        XCTAssertFalse(small === largeImage)
        XCTAssertTrue(fixture.service.cachedImage(for: fixture.media[0]) === largeImage)
        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 2)
    }

    func testCancellingTheOnlyRequestStopsItsLoad() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)
        let service = fixture.service
        let media = fixture.media[0]
        await fixture.storage.holdDecrypts()

        let request = Task { await service.image(for: media, pixelSize: 384) }
        try await waitUntil { await fixture.storage.heldDecryptCount == 1 }
        request.cancel()
        await settleMainActor()
        await fixture.storage.releaseDecrypts()
        let cancelledResult = await request.value

        XCTAssertNil(cancelledResult)
        XCTAssertNil(service.cachedImage(for: media))
        let retried = await service.image(for: media, pixelSize: 384)
        XCTAssertNotNil(retried)
        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 2)
    }

    func testCancellingOneOfTwoRequestsKeepsTheLoadForTheOther() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)
        let service = fixture.service
        let media = fixture.media[0]
        await fixture.storage.holdDecrypts()

        let cancelled = Task { await service.image(for: media, pixelSize: 384) }
        let kept = Task { await service.image(for: media, pixelSize: 384) }
        try await waitUntil { await fixture.storage.heldDecryptCount == 1 }
        cancelled.cancel()
        await settleMainActor()
        await fixture.storage.releaseDecrypts()
        let keptResult = await kept.value

        let image = try XCTUnwrap(keptResult)
        XCTAssertTrue(service.cachedImage(for: media, pixelSize: 384) === image)
        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 1)
    }

    func testClearingTheCacheDropsEveryImage() async throws {
        let fixture = try makeFixture(thumbnailCount: 2)
        _ = await fixture.service.image(for: fixture.media[0], pixelSize: 256)
        _ = await fixture.service.image(for: fixture.media[1])

        fixture.service.clearCache()

        XCTAssertNil(fixture.service.cachedImage(for: fixture.media[0]))
        XCTAssertNil(fixture.service.cachedImage(for: fixture.media[1]))
    }

    func testRemovingImagesDropsOnlyThoseThumbnails() async throws {
        let fixture = try makeFixture(thumbnailCount: 2)
        _ = await fixture.service.image(for: fixture.media[0], pixelSize: 256)
        _ = await fixture.service.image(for: fixture.media[0])
        _ = await fixture.service.image(for: fixture.media[1], pixelSize: 256)

        fixture.service.removeImages(forThumbnailIdentifiers: [fixture.media[0].thumbnailIdentifier].compactMap { $0 })

        XCTAssertNil(fixture.service.cachedImage(for: fixture.media[0]))
        XCTAssertNil(fixture.service.cachedImage(for: fixture.media[0], pixelSize: 256))
        XCTAssertNotNil(fixture.service.cachedImage(for: fixture.media[1], pixelSize: 256))
    }

    func testPrefetchFillsTheCache() async throws {
        let fixture = try makeFixture(thumbnailCount: 3)
        let service = fixture.service
        let media = fixture.media

        service.prefetch(media) { _ in 256 }
        try await waitUntil { media.allSatisfy { service.cachedImage(for: $0, pixelSize: 256) != nil } }
        _ = await service.image(for: media[1], pixelSize: 256)

        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 3)
    }

    func testPrefetchCancelsEarlierPrefetchesThatAreNoLongerWanted() async throws {
        let fixture = try makeFixture(thumbnailCount: 2)
        let service = fixture.service
        let media = fixture.media
        await fixture.storage.holdDecrypts()

        service.prefetch([media[0]]) { _ in 256 }
        try await waitUntil { await fixture.storage.heldDecryptCount == 1 }
        service.prefetch([media[1]]) { _ in 256 }
        try await waitUntil { await fixture.storage.heldDecryptCount == 2 }
        await fixture.storage.releaseDecrypts()
        try await waitUntil { service.cachedImage(for: media[1], pixelSize: 256) != nil }
        await settleMainActor()

        XCTAssertNil(service.cachedImage(for: media[0], pixelSize: 256))
    }

    func testRemovingImagesStopsAnInFlightLoadFromCachingThem() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)
        let service = fixture.service
        let media = fixture.media[0]
        await fixture.storage.holdDecrypts()

        let request = Task { await service.image(for: media, pixelSize: 384) }
        try await waitUntil { await fixture.storage.heldDecryptCount == 1 }
        service.removeImages(forThumbnailIdentifiers: [media.thumbnailIdentifier].compactMap { $0 })
        await fixture.storage.releaseDecrypts()
        _ = await request.value

        XCTAssertNil(service.cachedImage(for: media))
    }

    func testClearingTheCacheDuringALoadKeepsItsImageOutAndTellsViewsToReload() async throws {
        let fixture = try makeFixture(thumbnailCount: 1)
        let service = fixture.service
        let media = fixture.media[0]
        let generation = service.generation
        await fixture.storage.holdDecrypts()

        let request = Task { await service.image(for: media, pixelSize: 384) }
        try await waitUntil { await fixture.storage.heldDecryptCount == 1 }
        service.clearCache()
        await fixture.storage.releaseDecrypts()
        _ = await request.value

        XCTAssertNil(service.cachedImage(for: media))
        XCTAssertNotEqual(service.generation, generation)
    }

    func testMediaWithoutAThumbnailHasNoImage() async throws {
        let fixture = try makeFixture(thumbnailCount: 0)
        let media = VaultMedia(
            storageIdentifier: UUID().uuidString,
            contentFingerprint: UUID().uuidString,
            metadata: Benchmark.metadata(filename: "IMG_0001.JPG", width: 100, height: 100, byteCount: 100)
        )
        fixture.container.mainContext.insert(media)

        let image = await fixture.service.image(for: media)

        XCTAssertNil(image)
        let decryptCount = await fixture.storage.decryptCount
        XCTAssertEqual(decryptCount, 0)
    }

    func testPixelSizesRoundUpToStepsAndStopAtTheStoredSize() {
        XCTAssertEqual(ThumbnailService.pixelSize(forPoints: 114, scale: 3), 384)
        XCTAssertEqual(ThumbnailService.pixelSize(forPoints: 104.3, scale: 2), 256)
        XCTAssertEqual(ThumbnailService.pixelSize(forPoints: 76, scale: 3), 256)
        XCTAssertEqual(ThumbnailService.pixelSize(forPoints: 300, scale: 3), ThumbnailService.storedPixelSize)
        XCTAssertEqual(ThumbnailService.pixelSize(forPoints: 0, scale: 3), ThumbnailService.storedPixelSize)
        XCTAssertEqual(ThumbnailService.steppedPixelSize(1), 64)
        XCTAssertEqual(ThumbnailService.steppedPixelSize(64), 64)
        XCTAssertEqual(ThumbnailService.steppedPixelSize(65), 128)
    }

    func testFillingASquareNeedsTheLongSideScaledByTheAspectRatio() {
        let landscape = CGSize(width: 4_032, height: 3_024)

        XCTAssertEqual(ThumbnailService.pixelSize(fillingSquareOf: 114, scale: 3, mediaPixelSize: landscape), 512)
        XCTAssertEqual(
            ThumbnailService.pixelSize(fillingSquareOf: 114, scale: 3, mediaPixelSize: CGSize(width: 3_024, height: 4_032)),
            512
        )
        XCTAssertEqual(
            ThumbnailService.pixelSize(fillingSquareOf: 114, scale: 3, mediaPixelSize: CGSize(width: 1_000, height: 1_000)),
            384
        )
        XCTAssertEqual(
            ThumbnailService.pixelSize(fillingSquareOf: 114, scale: 3, mediaPixelSize: CGSize(width: 8_000, height: 2_000)),
            ThumbnailService.storedPixelSize
        )
        XCTAssertEqual(ThumbnailService.pixelSize(fillingSquareOf: 114, scale: 3, mediaPixelSize: .zero), 384)
    }

    func testDownsamplingKeepsTheAspectRatio() throws {
        let jpeg = Benchmark.photoJPEG(width: 600, height: 900, seed: 3)

        let image = ThumbnailService.downsampledImage(from: jpeg, maximumPixelSize: 300)
        let cgImage = try XCTUnwrap(image?.cgImage)

        XCTAssertEqual(cgImage.height, 300)
        XCTAssertEqual(cgImage.width, 200)
    }

    private struct Fixture {
        let container: ModelContainer
        let service: ThumbnailService
        let storage: ThumbnailStorageFake
        let media: [VaultMedia]
    }

    private func makeFixture(thumbnailCount: Int) throws -> Fixture {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        var payloads: [String: Data] = [:]
        var media: [VaultMedia] = []
        for index in 0..<thumbnailCount {
            let identifier = UUID().uuidString.lowercased()
            payloads[identifier] = Benchmark.photoJPEG(width: 720, height: 540, seed: UInt64(index + 1), quality: 0.82)
            let item = VaultMedia(
                storageIdentifier: UUID().uuidString.lowercased(),
                contentFingerprint: UUID().uuidString,
                thumbnailIdentifier: identifier,
                metadata: Benchmark.metadata(filename: "IMG_\(index).JPG", width: 4_032, height: 3_024, byteCount: 100)
            )
            container.mainContext.insert(item)
            media.append(item)
        }
        try container.mainContext.save()
        let storage = ThumbnailStorageFake(payloads: payloads)
        return Fixture(container: container, service: ThumbnailService(storage: storage), storage: storage, media: media)
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the condition")
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Lets main-actor work scheduled by a cancellation handler run.
    private func settleMainActor() async {
        for _ in 0..<20 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
