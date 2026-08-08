import XCTest
@testable import QuietFrame

final class ImportSummaryTests: XCTestCase {
    func testDeletionOfferAppearsAfterImportAndRequiresEveryIdentifier() {
        var summary = ImportSummary()
        XCTAssertFalse(summary.shouldOfferOriginalDeletion)
        XCTAssertTrue(summary.canDeleteImportedOriginals)

        summary.importedCount = 2
        summary.importedSourceLocalIdentifiers = ["first"]
        XCTAssertTrue(summary.shouldOfferOriginalDeletion)
        XCTAssertFalse(summary.canDeleteImportedOriginals)

        summary.importedSourceLocalIdentifiers.append("second")
        XCTAssertTrue(summary.canDeleteImportedOriginals)
    }
}
