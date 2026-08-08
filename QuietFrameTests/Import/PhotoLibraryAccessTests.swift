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

    func testDeletionRequiresOneUnadjustedPrimaryResource() {
        XCTAssertTrue(PhotoLibraryService.isSafeDeletionResourceProfile(
            mediaType: .image,
            mediaSubtypes: [],
            hasAdjustments: false,
            representsBurst: false,
            resourceTypes: [.photo]
        ))
        XCTAssertTrue(PhotoLibraryService.isSafeDeletionResourceProfile(
            mediaType: .video,
            mediaSubtypes: [],
            hasAdjustments: false,
            representsBurst: false,
            resourceTypes: [.video]
        ))
        XCTAssertFalse(PhotoLibraryService.isSafeDeletionResourceProfile(
            mediaType: .image,
            mediaSubtypes: [],
            hasAdjustments: true,
            representsBurst: false,
            resourceTypes: [.photo]
        ))
        XCTAssertFalse(PhotoLibraryService.isSafeDeletionResourceProfile(
            mediaType: .image,
            mediaSubtypes: .photoLive,
            hasAdjustments: false,
            representsBurst: false,
            resourceTypes: [.photo]
        ))
        XCTAssertFalse(PhotoLibraryService.isSafeDeletionResourceProfile(
            mediaType: .image,
            mediaSubtypes: [],
            hasAdjustments: false,
            representsBurst: true,
            resourceTypes: [.photo]
        ))
        XCTAssertFalse(PhotoLibraryService.isSafeDeletionResourceProfile(
            mediaType: .image,
            mediaSubtypes: [],
            hasAdjustments: false,
            representsBurst: false,
            resourceTypes: [.photo, .photo]
        ))
    }
}
