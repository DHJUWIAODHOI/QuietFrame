import XCTest
@testable import QuietFrame

final class MediaViewerPagingTests: XCTestCase {
    func testPreparationWindowIncludesSelectedAndImmediateNeighbors() {
        let states = (0..<5).map { mediaPageState(pageIndex: $0, selectedIndex: 2) }

        XCTAssertFalse(states[0].shouldPrepare)
        XCTAssertTrue(states[1].shouldPrepare)
        XCTAssertFalse(states[1].isActive)
        XCTAssertTrue(states[2].shouldPrepare)
        XCTAssertTrue(states[2].isActive)
        XCTAssertTrue(states[3].shouldPrepare)
        XCTAssertFalse(states[3].isActive)
        XCTAssertFalse(states[4].shouldPrepare)
    }

    func testSelectingPreparedNeighborSlidesPreparationWindow() {
        let neighborBeforeSelection = mediaPageState(pageIndex: 2, selectedIndex: 1)
        XCTAssertTrue(neighborBeforeSelection.shouldPrepare)
        XCTAssertFalse(neighborBeforeSelection.isActive)

        let neighborAfterSelection = mediaPageState(pageIndex: 2, selectedIndex: 2)
        XCTAssertTrue(neighborAfterSelection.shouldPrepare)
        XCTAssertTrue(neighborAfterSelection.isActive)
        XCTAssertFalse(mediaPageState(pageIndex: 0, selectedIndex: 2).shouldPrepare)
        XCTAssertTrue(mediaPageState(pageIndex: 3, selectedIndex: 2).shouldPrepare)
    }

    func testPreparationWindowStopsAtSnapshotEdges() {
        XCTAssertTrue(mediaPageState(pageIndex: 0, selectedIndex: 0).isActive)
        XCTAssertTrue(mediaPageState(pageIndex: 1, selectedIndex: 0).shouldPrepare)
        XCTAssertFalse(mediaPageState(pageIndex: 2, selectedIndex: 0).shouldPrepare)

        XCTAssertTrue(mediaPageState(pageIndex: 4, selectedIndex: 4).isActive)
        XCTAssertTrue(mediaPageState(pageIndex: 3, selectedIndex: 4).shouldPrepare)
        XCTAssertFalse(mediaPageState(pageIndex: 2, selectedIndex: 4).shouldPrepare)
    }
}
