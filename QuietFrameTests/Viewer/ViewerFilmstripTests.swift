import XCTest
@testable import QuietFrame

final class ViewerFilmstripTests: XCTestCase {
    func testWindowCentresOnTheSelectedItem() {
        XCTAssertEqual(filmstripWindow(selectedIndex: 10, count: 30, perSide: 3), 7..<14)
    }

    func testWindowStopsAtTheStartOfTheList() {
        XCTAssertEqual(filmstripWindow(selectedIndex: 1, count: 30, perSide: 3), 0..<5)
        XCTAssertEqual(filmstripWindow(selectedIndex: 0, count: 30, perSide: 3), 0..<4)
    }

    func testWindowStopsAtTheEndOfTheList() {
        XCTAssertEqual(filmstripWindow(selectedIndex: 28, count: 30, perSide: 3), 25..<30)
        XCTAssertEqual(filmstripWindow(selectedIndex: 29, count: 30, perSide: 3), 26..<30)
    }

    func testWindowIsEmptyWithoutAValidSelection() {
        XCTAssertTrue(filmstripWindow(selectedIndex: 0, count: 0, perSide: 3).isEmpty)
        XCTAssertTrue(filmstripWindow(selectedIndex: 5, count: 3, perSide: 3).isEmpty)
        XCTAssertTrue(filmstripWindow(selectedIndex: -1, count: 3, perSide: 3).isEmpty)
    }

    func testSingleItemWindowHoldsOnlyThatItem() {
        XCTAssertEqual(filmstripWindow(selectedIndex: 0, count: 1, perSide: 7), 0..<1)
        XCTAssertEqual(filmstripWindow(selectedIndex: 2, count: 5, perSide: -1), 2..<3)
    }

    func testWindowWiderThanTheListCoversEveryItem() {
        XCTAssertEqual(filmstripWindow(selectedIndex: 2, count: 5, perSide: 20), 0..<5)
    }

    func testTilesPerSideReachTheStripEdges() {
        XCTAssertEqual(filmstripTilesPerSide(width: 390), 7)
        XCTAssertEqual(filmstripTilesPerSide(width: 52), 1)
        XCTAssertEqual(filmstripTilesPerSide(width: 0), 1)
        XCTAssertEqual(filmstripTilesPerSide(width: .infinity), 1)
    }

    func testOnlyTilesClearOfTheFadedEdgesTakeTaps() {
        XCTAssertTrue(filmstripTileIsTappable(distance: 0, stripWidth: 390))
        XCTAssertTrue(filmstripTileIsTappable(distance: 5, stripWidth: 390))
        XCTAssertFalse(filmstripTileIsTappable(distance: 6, stripWidth: 390))
        XCTAssertTrue(filmstripTileIsTappable(distance: 8, stripWidth: 560))
        XCTAssertFalse(filmstripTileIsTappable(distance: 9, stripWidth: 560))
        XCTAssertFalse(filmstripTileIsTappable(distance: filmstripTilesPerSide(width: 560), stripWidth: 560))
    }
}
