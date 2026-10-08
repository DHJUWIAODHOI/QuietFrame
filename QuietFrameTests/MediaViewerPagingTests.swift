import SwiftUI
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

    func testPreparationOrderPrioritizesSelectedThenNextThenPrevious() {
        XCTAssertEqual(mediaPreparationOrder(selectedIndex: 2, count: 5), [2, 3, 1])
        XCTAssertEqual(mediaPreparationOrder(selectedIndex: 0, count: 5), [0, 1])
        XCTAssertEqual(mediaPreparationOrder(selectedIndex: 4, count: 5), [4, 3])
        XCTAssertEqual(mediaPreparationOrder(selectedIndex: 0, count: 1), [0])
        XCTAssertEqual(mediaPreparationOrder(selectedIndex: 0, count: 0), [])
        XCTAssertEqual(mediaPreparationOrder(selectedIndex: 5, count: 5), [])
    }

    func testPreparationOrderCoversExactlyThePreparationWindow() {
        for selectedIndex in 0..<5 {
            let ordered = mediaPreparationOrder(selectedIndex: selectedIndex, count: 5)
            let window = (0..<5).filter {
                mediaPageState(pageIndex: $0, selectedIndex: selectedIndex).shouldPrepare
            }
            XCTAssertEqual(Set(ordered), Set(window))
            XCTAssertEqual(ordered.count, window.count)
        }
    }

    func testVideoIsDecryptedOnlyForTheSelectedPage() {
        XCTAssertEqual(videoPageAction(shouldPrepare: true, isActive: true, scenePhase: .active), .load)
        XCTAssertEqual(videoPageAction(shouldPrepare: true, isActive: false, scenePhase: .active), .idle)
        XCTAssertEqual(videoPageAction(shouldPrepare: true, isActive: true, scenePhase: .inactive), .pause)
        XCTAssertEqual(videoPageAction(shouldPrepare: true, isActive: true, scenePhase: .background), .pause)
        XCTAssertEqual(videoPageAction(shouldPrepare: false, isActive: false, scenePhase: .active), .cleanup)
        XCTAssertEqual(videoPageAction(shouldPrepare: false, isActive: false, scenePhase: .background), .cleanup)
    }

    func testControlsHideWhileSelectedVideoPlaysAndReturnWhenItPauses() {
        XCTAssertEqual(
            viewerControlsVisibility(afterPlaybackChange: true, isSelectedPage: true, controlsAreVisible: true),
            false
        )
        XCTAssertEqual(
            viewerControlsVisibility(afterPlaybackChange: false, isSelectedPage: true, controlsAreVisible: false),
            true
        )
        XCTAssertNil(
            viewerControlsVisibility(afterPlaybackChange: false, isSelectedPage: true, controlsAreVisible: true)
        )
        XCTAssertNil(
            viewerControlsVisibility(afterPlaybackChange: true, isSelectedPage: true, controlsAreVisible: false)
        )
        XCTAssertNil(
            viewerControlsVisibility(afterPlaybackChange: false, isSelectedPage: false, controlsAreVisible: false)
        )
        XCTAssertNil(
            viewerControlsVisibility(afterPlaybackChange: true, isSelectedPage: false, controlsAreVisible: true)
        )
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
