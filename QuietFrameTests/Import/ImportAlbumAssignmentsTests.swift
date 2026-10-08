import XCTest
@testable import QuietFrame

final class ImportAlbumAssignmentsTests: XCTestCase {
    private let family = UUID()
    private let documents = UUID()

    func testAssigningSelectionRoutesOnlySelectedItemsAndEndsSelection() {
        let items = (0..<4).map { _ in UUID() }
        var assignments = ImportAlbumAssignments()

        assignments.toggleSelection(items[0])
        assignments.toggleSelection(items[1])
        assignments.assignSelection(to: family)

        XCTAssertFalse(assignments.hasSelection)
        XCTAssertEqual(assignments.albumID(for: items[0]), family)
        XCTAssertEqual(assignments.albumID(for: items[1]), family)
        XCTAssertNil(assignments.albumID(for: items[2]))

        assignments.toggleSelection(items[2])
        assignments.assignSelection(to: documents)

        XCTAssertEqual(assignments.destination(for: items[0], defaultAlbumID: nil), family)
        XCTAssertEqual(assignments.destination(for: items[2], defaultAlbumID: nil), documents)
        XCTAssertNil(assignments.destination(for: items[3], defaultAlbumID: nil))
    }

    func testUnassignedItemsUseTheDefaultDestination() {
        let assigned = UUID()
        let unassigned = UUID()
        let defaultAlbum = UUID()
        var assignments = ImportAlbumAssignments()

        assignments.toggleSelection(assigned)
        assignments.assignSelection(to: family)

        XCTAssertEqual(assignments.destination(for: assigned, defaultAlbumID: defaultAlbum), family)
        XCTAssertEqual(assignments.destination(for: unassigned, defaultAlbumID: defaultAlbum), defaultAlbum)
    }

    func testAssigningNilReturnsItemsToTheDefault() {
        let item = UUID()
        var assignments = ImportAlbumAssignments()
        assignments.toggleSelection(item)
        assignments.assignSelection(to: family)

        assignments.toggleSelection(item)
        assignments.assignSelection(to: nil)

        XCTAssertNil(assignments.albumID(for: item))
        XCTAssertFalse(assignments.hasAssignments)
    }

    func testToggleSelectAllAndClear() {
        let items = (0..<3).map { _ in UUID() }
        var assignments = ImportAlbumAssignments()

        assignments.toggleSelection(items[0])
        XCTAssertTrue(assignments.isSelected(items[0]))
        assignments.toggleSelection(items[0])
        XCTAssertFalse(assignments.isSelected(items[0]))

        assignments.select(items)
        XCTAssertEqual(assignments.selectedIDs, Set(items))

        assignments.clearSelection()
        XCTAssertFalse(assignments.hasSelection)
    }

    func testSelectionAlbumIsSharedAlbumOnly() {
        let items = (0..<3).map { _ in UUID() }
        var assignments = ImportAlbumAssignments()
        assignments.select([items[0], items[1]])
        assignments.assignSelection(to: family)

        assignments.select([items[0], items[1]])
        XCTAssertEqual(assignments.selectionAlbumID, family)

        assignments.toggleSelection(items[2])
        XCTAssertNil(assignments.selectionAlbumID)

        assignments.clearSelection()
        XCTAssertNil(assignments.selectionAlbumID)
    }

    func testRemovingAnItemForgetsItsSelectionAndAlbum() {
        let item = UUID()
        var assignments = ImportAlbumAssignments()
        assignments.toggleSelection(item)
        assignments.assignSelection(to: family)
        assignments.toggleSelection(item)

        assignments.remove(item)

        XCTAssertFalse(assignments.isSelected(item))
        XCTAssertNil(assignments.albumID(for: item))
    }

    func testDeletedAlbumsFallBackToTheDefault() {
        let kept = UUID()
        let orphaned = UUID()
        var assignments = ImportAlbumAssignments()
        assignments.toggleSelection(kept)
        assignments.assignSelection(to: family)
        assignments.toggleSelection(orphaned)
        assignments.assignSelection(to: documents)

        assignments.discardAlbums(notIn: [family])

        XCTAssertEqual(assignments.albumID(for: kept), family)
        XCTAssertNil(assignments.albumID(for: orphaned))
    }

    func testResetClearsEverything() {
        let item = UUID()
        var assignments = ImportAlbumAssignments()
        assignments.toggleSelection(item)
        assignments.assignSelection(to: family)
        assignments.toggleSelection(item)

        assignments.reset()

        XCTAssertEqual(assignments, ImportAlbumAssignments())
    }
}
