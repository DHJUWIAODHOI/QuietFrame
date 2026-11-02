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

    /// The deferred check applies the picker's old rule to a fake asset lookup; real PhotoKit is never touched.
    func testDeferredChecksFollowTheEligibilityRules() {
        let safePhoto = assetProfile(mediaType: .image, resourceTypes: [.photo])
        let safeVideo = assetProfile(mediaType: .video, resourceTypes: [.video])

        XCTAssertEqual(resolve("photo", profile: safePhoto), "photo")
        XCTAssertEqual(resolve("video", profile: safeVideo), "video")
        XCTAssertNil(resolve("missing", profile: nil))
        XCTAssertNil(resolve("edited", profile: assetProfile(mediaType: .image, hasAdjustments: true, resourceTypes: [.photo])))
        XCTAssertNil(resolve("burst", profile: assetProfile(mediaType: .image, representsBurst: true, resourceTypes: [.photo])))
        XCTAssertNil(resolve("live", profile: assetProfile(mediaType: .image, mediaSubtypes: .photoLive, resourceTypes: [.photo])))
        XCTAssertNil(resolve("paired", profile: assetProfile(mediaType: .image, resourceTypes: [.photo, .photo])))
        XCTAssertNil(resolve("mismatched", profile: assetProfile(mediaType: .image, resourceTypes: [.video])))
    }

    func testDeferredChecksSkipThePhotoLibraryWhenTheAnswerIsKnown() {
        var lookups: [String] = []
        let lookup: (String) -> PhotoLibraryAssetProfile? = { identifier in
            lookups.append(identifier)
            return self.assetProfile(mediaType: .image, resourceTypes: [.photo])
        }

        let missing = PhotoLibraryService.sourceIdentifier(
            for: .pending(assetIdentifier: nil, providerHasLivePhoto: false),
            assetProfile: lookup
        )
        let empty = PhotoLibraryService.sourceIdentifier(
            for: .pending(assetIdentifier: "", providerHasLivePhoto: false),
            assetProfile: lookup
        )
        let livePhoto = PhotoLibraryService.sourceIdentifier(
            for: .pending(assetIdentifier: "live", providerHasLivePhoto: true),
            assetProfile: lookup
        )
        let decided = PhotoLibraryService.sourceIdentifier(for: .resolved("decided"), assetProfile: lookup)
        let declined = PhotoLibraryService.sourceIdentifier(for: .resolved(nil), assetProfile: lookup)
        let asked = PhotoLibraryService.sourceIdentifier(
            for: .pending(assetIdentifier: "asked", providerHasLivePhoto: false),
            assetProfile: lookup
        )

        XCTAssertNil(missing)
        XCTAssertNil(empty)
        XCTAssertNil(livePhoto)
        XCTAssertEqual(decided, "decided")
        XCTAssertNil(declined)
        XCTAssertEqual(asked, "asked")
        XCTAssertEqual(lookups, ["asked"])
    }

    private func resolve(_ identifier: String, profile: PhotoLibraryAssetProfile?) -> String? {
        PhotoLibraryService.sourceIdentifier(
            for: .pending(assetIdentifier: identifier, providerHasLivePhoto: false),
            assetProfile: { _ in profile }
        )
    }

    private func assetProfile(
        mediaType: PHAssetMediaType,
        mediaSubtypes: PHAssetMediaSubtype = [],
        hasAdjustments: Bool = false,
        representsBurst: Bool = false,
        resourceTypes: [PHAssetResourceType]
    ) -> PhotoLibraryAssetProfile {
        PhotoLibraryAssetProfile(
            mediaType: mediaType,
            mediaSubtypes: mediaSubtypes,
            hasAdjustments: hasAdjustments,
            representsBurst: representsBurst,
            resourceTypes: resourceTypes
        )
    }
}
