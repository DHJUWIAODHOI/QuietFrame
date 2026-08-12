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
        XCTAssertTrue(authorized.allowsSourceDeletionInspection)
        XCTAssertTrue(limited.allowsSourceDeletionInspection)
        XCTAssertFalse(denied.allowsSourceDeletionInspection)
        XCTAssertFalse(restricted.allowsSourceDeletionInspection)
    }

    func testLimitedAccessAllowsOnlyIdentifiableAccessibleSafeAssets() {
        let allowsInspection = PhotoLibraryImportAccess.limited.allowsSourceDeletionInspection
        XCTAssertEqual(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: allowsInspection,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ), "asset-id")
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            nil,
            allowsInspection: allowsInspection,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "",
            allowsInspection: allowsInspection,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: allowsInspection,
            assetIsAccessible: false,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: allowsInspection,
            assetIsAccessible: true,
            providerHasLivePhoto: true,
            resourceProfileIsSafe: true
        ))
        XCTAssertNil(PhotoLibraryService.eligibleSourceIdentifier(
            "asset-id",
            allowsInspection: allowsInspection,
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
            allowsInspection: PhotoLibraryImportAccess.denied.allowsSourceDeletionInspection,
            assetIsAccessible: true,
            providerHasLivePhoto: false,
            resourceProfileIsSafe: true
        ))
    }
}
