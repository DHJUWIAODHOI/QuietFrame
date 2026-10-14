import CoreGraphics
import XCTest
@testable import QuietFrame

final class ViewerDetailsLayoutTests: XCTestCase {
    private let viewerBounds = CGRect(x: 0, y: 0, width: 390, height: 756)

    func testPortraitPhotoRestsOnThePanel() {
        let offset = detailsMediaOffset(
            mediaSize: CGSize(width: 3_024, height: 4_032),
            viewerBounds: viewerBounds,
            panelTop: 355
        )

        XCTAssertEqual(offset, -283, accuracy: 0.01)
    }

    func testLandscapeVideoRestsOnThePanel() {
        let offset = detailsMediaOffset(
            mediaSize: CGSize(width: 1_920, height: 1_080),
            viewerBounds: viewerBounds,
            panelTop: 355
        )

        XCTAssertEqual(offset, -132.6875, accuracy: 0.01)
    }

    func testMediaAlreadyAboveThePanelStaysPut() {
        let offset = detailsMediaOffset(
            mediaSize: CGSize(width: 100, height: 100),
            viewerBounds: viewerBounds,
            panelTop: 600
        )

        XCTAssertEqual(offset, 0, accuracy: 0.001)
    }

    func testPanelTopSitsJustUnderHalfTheViewer() {
        XCTAssertEqual(detailsPanelTop(viewerHeight: 756, topBarBottom: 44), 355.32, accuracy: 0.001)
        XCTAssertEqual(detailsPanelTop(viewerHeight: 0, topBarBottom: 44), 0, accuracy: 0.001)
    }

    func testPanelTopKeepsClearOfTheTopBar() {
        XCTAssertEqual(detailsPanelTop(viewerHeight: 300, topBarBottom: 44), 164, accuracy: 0.001)
        XCTAssertEqual(detailsPanelTop(viewerHeight: 100, topBarBottom: 44), 100, accuracy: 0.001)
    }

    func testUpwardSwipeOpensDetails() {
        XCTAssertTrue(shouldOpenDetails(translation: -61, velocity: 0))
        XCTAssertFalse(shouldOpenDetails(translation: -60, velocity: 0))
        XCTAssertTrue(shouldOpenDetails(translation: -13, velocity: -501))
        XCTAssertFalse(shouldOpenDetails(translation: -12, velocity: -2_000))
        XCTAssertFalse(shouldOpenDetails(translation: 100, velocity: -2_000))
    }

    func testDimensionsFollowTheShownOrientation() {
        XCTAssertEqual(
            viewerDimensions(pixelWidth: 4_032, pixelHeight: 3_024, displaySize: CGSize(width: 3_024, height: 4_032)),
            "3024 \u{00D7} 4032"
        )
        XCTAssertEqual(
            viewerDimensions(pixelWidth: 4_032, pixelHeight: 3_024, displaySize: CGSize(width: 400, height: 300)),
            "4032 \u{00D7} 3024"
        )
        XCTAssertEqual(
            viewerDimensions(pixelWidth: 1_000, pixelHeight: 1_001, displaySize: CGSize(width: 300, height: 300)),
            "1000 \u{00D7} 1001"
        )
    }

    func testDownwardSwipeClosesDetails() {
        XCTAssertTrue(shouldCloseDetails(translation: 41, velocity: 0))
        XCTAssertFalse(shouldCloseDetails(translation: 40, velocity: 0))
        XCTAssertTrue(shouldCloseDetails(translation: 13, velocity: 401))
        XCTAssertFalse(shouldCloseDetails(translation: 12, velocity: 2_000))
        XCTAssertFalse(shouldCloseDetails(translation: -100, velocity: 2_000))
    }
}
