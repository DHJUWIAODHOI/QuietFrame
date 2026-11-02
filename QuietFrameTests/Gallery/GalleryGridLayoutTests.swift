import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class GalleryGridLayoutTests: XCTestCase {
    func testComfortableTilesFillThreeColumnsOnAnIPhone() {
        let width = adaptiveGridTileWidth(availableWidth: 354, minimum: 102, maximum: 174, spacing: 6)

        XCTAssertEqual(width, 114, accuracy: 0.001)
    }

    func testWideGridsFitMoreColumns() {
        let width = adaptiveGridTileWidth(availableWidth: 1_318, minimum: 102, maximum: 174, spacing: 6)

        XCTAssertEqual(width, (1_318 - 66) / 12, accuracy: 0.001)
    }

    func testAccessibilitySizesUseOneColumn() {
        let width = adaptiveGridTileWidth(availableWidth: 354, minimum: 280, maximum: 560, spacing: 6)

        XCTAssertEqual(width, 354, accuracy: 0.001)
    }

    func testTilesNeverExceedTheMaximumWidth() {
        let width = adaptiveGridTileWidth(availableWidth: 300, minimum: 100, maximum: 120, spacing: 0)

        XCTAssertEqual(width, 100, accuracy: 0.001)
        XCTAssertEqual(adaptiveGridTileWidth(availableWidth: 150, minimum: 100, maximum: 120, spacing: 0), 120)
    }

    func testTileFramesFollowTheScrolledContentOrigin() {
        let tileFrames = MediaTileFrames()
        let mediaID = UUID()
        tileFrames.set(CGRect(x: 24, y: 600, width: 114, height: 114), for: mediaID)

        tileFrames.contentOrigin = CGPoint(x: 0, y: -420)

        XCTAssertEqual(tileFrames.frame(for: mediaID), CGRect(x: 24, y: 180, width: 114, height: 114))
    }

    func testItemIndexesFollowRefreshes() async throws {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let media = (0..<4).map { index in
            VaultMedia(
                storageIdentifier: "item-\(index)",
                contentFingerprint: "fingerprint-\(index)",
                metadata: Benchmark.metadata(filename: "IMG_\(index).JPG", width: 10, height: 10, byteCount: 10),
                importedAt: Date(timeIntervalSince1970: TimeInterval(index * 100))
            )
        }
        media.forEach { context.insert($0) }
        try context.save()
        let viewModel = GalleryViewModel(repository: VaultRepository(modelContext: context), query: GalleryQuery())
        await viewModel.loadInitial()

        XCTAssertEqual(viewModel.index(of: media[3].id), 0)
        XCTAssertEqual(viewModel.index(of: media[0].id), 3)

        media[2].trashedAt = Date()
        try context.save()
        await viewModel.refreshLoadedItems()

        XCTAssertEqual(viewModel.index(of: media[1].id), 1)
        XCTAssertEqual(viewModel.index(of: media[0].id), 2)
        XCTAssertNil(viewModel.index(of: media[2].id))
    }
}
