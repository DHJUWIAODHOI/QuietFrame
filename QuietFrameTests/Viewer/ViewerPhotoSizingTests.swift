import SwiftData
import UIKit
import XCTest
@testable import QuietFrame

@MainActor
final class ViewerPhotoSizingTests: XCTestCase {
    private let phone = CGSize(width: 1_206, height: 2_622)

    func testLandscapePhotoFillsThePhoneInEitherOrientation() {
        let photo = CGSize(width: 4_032, height: 3_024)

        XCTAssertEqual(viewerFitPixelSize(photoPixelSize: photo, viewerPixelSize: phone), 1_608)
        XCTAssertEqual(
            viewerFitPixelSize(photoPixelSize: photo, viewerPixelSize: CGSize(width: 2_622, height: 1_206)),
            1_608
        )
        XCTAssertEqual(
            viewerFitPixelSize(photoPixelSize: CGSize(width: 3_024, height: 4_032), viewerPixelSize: phone),
            1_608
        )
    }

    func testPanoramasAndSquaresUseTheSpaceTheyCanFill() {
        XCTAssertEqual(viewerFitPixelSize(photoPixelSize: CGSize(width: 8_000, height: 2_000), viewerPixelSize: phone), 2_622)
        XCTAssertEqual(viewerFitPixelSize(photoPixelSize: CGSize(width: 3_000, height: 3_000), viewerPixelSize: phone), 1_206)
    }

    func testSmallPhotosAreNeverDecodedLargerThanThemselves() {
        XCTAssertEqual(viewerFitPixelSize(photoPixelSize: CGSize(width: 800, height: 600), viewerPixelSize: phone), 800)
    }

    func testUnknownSizesDecodeAtTheZoomSize() {
        XCTAssertEqual(viewerFitPixelSize(photoPixelSize: .zero, viewerPixelSize: phone), ViewerPhotoRequest.zoomPixelSize)
        XCTAssertEqual(
            viewerFitPixelSize(photoPixelSize: CGSize(width: 4_032, height: 3_024), viewerPixelSize: .zero),
            ViewerPhotoRequest.zoomPixelSize
        )
        XCTAssertEqual(
            viewerFitPixelSize(photoPixelSize: CGSize(width: 20_000, height: 15_000), viewerPixelSize: CGSize(width: 9_000, height: 9_000)),
            ViewerPhotoRequest.zoomPixelSize
        )
    }

    func testZoomingAPhotoAlreadyShownAtFullSizeRequestsNothingSharper() {
        let camera = CGSize(width: 4_032, height: 3_024)

        XCTAssertEqual(
            viewerPhotoPixelSize(photoPixelSize: CGSize(width: 1_600, height: 1_200), viewerPixelSize: phone, isZoomed: true),
            1_600
        )
        XCTAssertEqual(viewerPhotoPixelSize(photoPixelSize: camera, viewerPixelSize: phone, isZoomed: false), 1_608)
        XCTAssertEqual(
            viewerPhotoPixelSize(photoPixelSize: camera, viewerPixelSize: phone, isZoomed: true),
            ViewerPhotoRequest.zoomPixelSize
        )
        XCTAssertEqual(
            viewerPhotoPixelSize(photoPixelSize: .zero, viewerPixelSize: phone, isZoomed: true),
            ViewerPhotoRequest.zoomPixelSize
        )
    }

    func testLargerRequestSwapsInASharperCopy() async throws {
        let (loader, storage, identifier) = makeLoader()
        let request = ViewerPhotoRequest(mediaID: UUID(), storageIdentifier: identifier, location: .media, pixelSize: 200)

        loader.prepare([request])
        try await waitUntil { loader.image(for: request.mediaID) != nil }
        let small = try XCTUnwrap(loader.image(for: request.mediaID)?.cgImage)
        var zoomed = request
        zoomed.pixelSize = ViewerPhotoRequest.zoomPixelSize
        loader.prepare([zoomed])
        try await waitUntil { (loader.image(for: request.mediaID)?.cgImage?.width ?? 0) > small.width }

        let sharp = try XCTUnwrap(loader.image(for: request.mediaID)?.cgImage)
        XCTAssertEqual(max(small.width, small.height), 200)
        XCTAssertEqual(max(sharp.width, sharp.height), 1_200)
        let decryptCount = await storage.decryptCount
        XCTAssertEqual(decryptCount, 2)
    }

    func testSmallerRequestKeepsTheSharperCopyOfTheSelectedPhoto() async throws {
        let (loader, storage, identifier) = makeLoader()
        let mediaID = UUID()
        let zoomed = ViewerPhotoRequest(mediaID: mediaID, storageIdentifier: identifier, location: .media)

        loader.prepare([zoomed])
        try await waitUntil { loader.image(for: mediaID) != nil }
        var unzoomed = zoomed
        unzoomed.pixelSize = 200
        loader.prepare([unzoomed])
        try await waitUntil { !loader.isLoading }

        XCTAssertEqual(loader.image(for: mediaID)?.cgImage?.width, 1_200)
        let decryptCount = await storage.decryptCount
        XCTAssertEqual(decryptCount, 1)
    }

    func testZoomedCopyOfAPhotoThatIsNoLongerSelectedIsDecodedAgainAtDisplaySize() async throws {
        let (loader, storage, identifier) = makeLoader()
        let mediaID = UUID()
        let zoomed = ViewerPhotoRequest(mediaID: mediaID, storageIdentifier: identifier, location: .media)
        let other = ViewerPhotoRequest(mediaID: UUID(), storageIdentifier: identifier, location: .media, pixelSize: 200)

        loader.prepare([zoomed])
        try await waitUntil { loader.image(for: mediaID) != nil }
        var neighbour = zoomed
        neighbour.pixelSize = 200
        loader.prepare([other, neighbour])

        XCTAssertEqual(loader.image(for: mediaID)?.cgImage?.width, 1_200, "The zoomed copy keeps showing meanwhile")
        try await waitUntil {
            loader.image(for: other.mediaID) != nil && loader.image(for: mediaID)?.cgImage?.width == 200
        }
        let decryptCount = await storage.decryptCount
        XCTAssertEqual(decryptCount, 3)
    }

    func testNeighbourOfASelectedVideoGivesUpItsZoomedCopy() async throws {
        let (loader, storage, identifier) = makeLoader()
        let mediaID = UUID()
        let zoomed = ViewerPhotoRequest(mediaID: mediaID, storageIdentifier: identifier, location: .media)

        loader.prepare([zoomed])
        try await waitUntil { loader.image(for: mediaID) != nil }
        var neighbour = zoomed
        neighbour.pixelSize = 200
        loader.prepare([neighbour], firstIsSelected: false)
        try await waitUntil { loader.image(for: mediaID)?.cgImage?.width == 200 }

        let decryptCount = await storage.decryptCount
        XCTAssertEqual(decryptCount, 2)
    }

    func testFailedSmallerCopyKeepsTheZoomedCopyAndIsNotRetried() async throws {
        let (loader, storage, identifier) = makeLoader()
        let mediaID = UUID()
        let zoomed = ViewerPhotoRequest(mediaID: mediaID, storageIdentifier: identifier, location: .media)

        loader.prepare([zoomed])
        try await waitUntil { loader.image(for: mediaID) != nil }
        await storage.setPayload(Data(repeating: 0x42, count: 64), for: identifier)
        var neighbour = zoomed
        neighbour.pixelSize = 200
        loader.prepare([neighbour], firstIsSelected: false)
        try await waitUntil { await storage.decryptCount == 2 }
        try await waitUntil { !loader.isLoading }
        loader.prepare([neighbour], firstIsSelected: false)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(loader.image(for: mediaID)?.cgImage?.width, 1_200)
        XCTAssertNil(loader.failureMessage(for: mediaID))
        let decryptCount = await storage.decryptCount
        XCTAssertEqual(decryptCount, 2)
    }

    func testFailedSharperCopyKeepsThePhotoAndIsNotRetried() async throws {
        let (loader, storage, identifier) = makeLoader()
        let mediaID = UUID()
        let request = ViewerPhotoRequest(mediaID: mediaID, storageIdentifier: identifier, location: .media, pixelSize: 200)

        loader.prepare([request])
        try await waitUntil { loader.image(for: mediaID) != nil }
        await storage.setPayload(Data(repeating: 0x42, count: 64), for: identifier)
        var zoomed = request
        zoomed.pixelSize = ViewerPhotoRequest.zoomPixelSize
        loader.prepare([zoomed])
        try await waitUntil { await storage.decryptCount == 2 }
        try await waitUntil { !loader.isLoading }
        loader.prepare([zoomed])
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(loader.image(for: mediaID)?.cgImage?.width, 200)
        XCTAssertNil(loader.failureMessage(for: mediaID))
        let decryptCount = await storage.decryptCount
        XCTAssertEqual(decryptCount, 2)
    }

    func testPositionIndexFollowsChangedItems() throws {
        let container = try ModelContainer(
            for: Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let media = (0..<3).map { index in
            VaultMedia(
                storageIdentifier: "item-\(index)",
                contentFingerprint: "fingerprint-\(index)",
                metadata: Benchmark.metadata(filename: "IMG_\(index).JPG", width: 10, height: 10, byteCount: 10)
            )
        }
        media.forEach { container.mainContext.insert($0) }
        let positions = MediaPositionIndex()
        let ids = media.map(\.id)

        XCTAssertEqual(positions.index(of: ids[2], in: ids), 2)
        XCTAssertEqual(positions.index(of: ids[0], in: Array(ids.reversed())), 2)
        XCTAssertEqual(positions.index(of: ids[1], in: [ids[1]]), 0)
        XCTAssertNil(positions.index(of: ids[2], in: [ids[0], ids[1]]))
    }

    private func makeLoader() -> (ViewerPhotoLoader, ThumbnailStorageFake, String) {
        let identifier = UUID().uuidString.lowercased()
        let storage = ThumbnailStorageFake(payloads: [
            identifier: Benchmark.photoJPEG(width: 1_200, height: 900, seed: 11)
        ])
        return (ViewerPhotoLoader(storage: storage), storage, identifier)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the viewer photo loader.")
    }
}
