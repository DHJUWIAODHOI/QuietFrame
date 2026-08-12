import Photos
import XCTest
@testable import QuietFrame

final class PhotoLibraryAccessTests: XCTestCase {
    func testAuthorizationStatusMappingForSafeDeletion() {
        let authorized = PhotoLibraryService.importAccess(for: .authorized)
        let limited = PhotoLibraryService.importAccess(for: .limited)
        let denied = PhotoLibraryService.importAccess(for: .denied)
        let restricted = PhotoLibraryService.importAccess(for: .restricted)
        XCTAssertEqual(authorized, .full)
        XCTAssertEqual(limited, .limited)
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(restricted, .denied)
        XCTAssertEqual(PhotoLibraryService.importAccess(for: .notDetermined), .denied)
    }

    func testLimitedAccessAllowsOnlyIdentifiableAccessibleSafeAssets() {
        XCTAssertEqual(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: true,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ), "asset-id")
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            nil,
            allowsInspection: true,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "",
            allowsInspection: true,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: true,
            assetIsAccessible: false,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: true,
            assetIsAccessible: true,
            providerHasLivePhoto: true,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: true,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: false
        ))
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

    func testDeniedAccessNeverAllowsSourceDeletionIdentifier() {
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: false,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
    }
}
