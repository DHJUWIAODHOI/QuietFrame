import XCTest
@testable import QuietFrame

@MainActor
final class MediaPositionIndexTests: XCTestCase {
    func testPositionsFollowTheListTheyAreAskedAbout() {
        let ids = (0..<4).map { _ in UUID() }
        let positions = MediaPositionIndex()

        XCTAssertEqual(positions.index(of: ids[2], in: ids), 2)
        XCTAssertEqual(positions.index(of: ids[0], in: [ids[3], ids[0]]), 1)
        XCTAssertNil(positions.index(of: ids[2], in: [ids[3], ids[0]]))
        XCTAssertEqual(positions.index(of: ids[2], in: ids), 2)
    }

    func testAMissingIDFindsNothingAndLeavesThePositionsIntact() {
        let ids = (0..<1_000).map { _ in UUID() }
        let positions = MediaPositionIndex()

        for _ in 0..<100 {
            XCTAssertNil(positions.index(of: UUID(), in: ids))
        }

        XCTAssertEqual(positions.index(of: ids[999], in: ids), 999)
        XCTAssertEqual(positions.index(of: ids[0], in: ids), 0)
    }

    func testAnEqualListInNewStorageGivesTheSamePositions() {
        let ids = (0..<5).map { _ in UUID() }
        let copy = ids.map { $0 }
        let positions = MediaPositionIndex()

        XCTAssertEqual(positions.index(of: ids[4], in: ids), 4)
        XCTAssertEqual(positions.index(of: ids[4], in: copy), 4)
        XCTAssertEqual(positions.index(of: ids[1], in: copy), 1)
    }

    func testItemsAppendedToTheSameArrayAreFound() {
        var ids = [UUID(), UUID()]
        let positions = MediaPositionIndex()
        XCTAssertEqual(positions.index(of: ids[1], in: ids), 1)

        let appended = UUID()
        ids.append(appended)

        XCTAssertEqual(positions.index(of: appended, in: ids), 2)
    }

    func testARepeatedIDKeepsItsFirstPosition() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(MediaPositionIndex().index(of: first, in: [first, second, first]), 0)
    }
}
