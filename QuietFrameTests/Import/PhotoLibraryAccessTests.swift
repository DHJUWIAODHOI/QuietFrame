import Photos
import XCTest
@testable import QuietFrame

final class PhotoLibraryAccessTests: XCTestCase {
    func testAuthorizationStatusMappingForSafeDeletion() {
        XCTAssertEqual(PhotoLibraryService.importAccess(for: .authorized), .full)
        XCTAssertEqual(PhotoLibraryService.importAccess(for: .limited), .limited)
        XCTAssertEqual(PhotoLibraryService.importAccess(for: .denied), .denied)
        XCTAssertEqual(PhotoLibraryService.importAccess(for: .restricted), .denied)
        XCTAssertEqual(PhotoLibraryService.importAccess(for: .notDetermined), .denied)
    }
}
