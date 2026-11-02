import Foundation
import Photos

enum PhotoLibraryImportAccess: Equatable, Sendable {
    case full
    case limited
    case denied
}

/// Whether an imported original may later be offered for deletion. The picker records what it knows; PhotoKit is
/// asked off the main thread while the selection is prepared.
enum PhotoLibraryDeletionCheck: Sendable, Equatable {
    /// Decided: the identifier, or nil when deletion will not be offered.
    case resolved(String?)
    /// Needs PhotoKit: the picker's asset identifier and whether the provider carries a Live Photo.
    case pending(assetIdentifier: String?, providerHasLivePhoto: Bool)

    var needsPhotoLibrary: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// The asset properties the deletion rule reads.
struct PhotoLibraryAssetProfile {
    let mediaType: PHAssetMediaType
    let mediaSubtypes: PHAssetMediaSubtype
    let hasAdjustments: Bool
    let representsBurst: Bool
    let resourceTypes: [PHAssetResourceType]
}

protocol PhotoLibraryServing: Sendable {
    func requestImportAccess() async -> PhotoLibraryImportAccess
    func deleteOriginals(localIdentifiers: [String]) async throws
    /// One identifier, or nil when deletion will not be offered, per check and in the same order.
    func sourceIdentifiers(for checks: [PhotoLibraryDeletionCheck]) async -> [String?]
}

actor PhotoLibraryService: PhotoLibraryServing {
    private static let queryQueue = DispatchQueue(
        label: "com.quietframe.vault.photo-library-queries",
        qos: .userInitiated
    )

    func requestImportAccess() async -> PhotoLibraryImportAccess {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return Self.importAccess(for: status)
    }

    static func importAccess(for status: PHAuthorizationStatus) -> PhotoLibraryImportAccess {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .denied, .restricted, .notDetermined: .denied
        @unknown default: .denied
        }
    }

    static func isSafeToDeleteAfterRepresentationImport(_ asset: PHAsset) -> Bool {
        isSafeDeletionResourceProfile(
            mediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            hasAdjustments: asset.hasAdjustments,
            representsBurst: asset.representsBurst,
            resourceTypes: PHAssetResource.assetResources(for: asset).map(\.type)
        )
    }

    static func isSafeDeletionResourceProfile(
        mediaType: PHAssetMediaType,
        mediaSubtypes: PHAssetMediaSubtype,
        hasAdjustments: Bool,
        representsBurst: Bool,
        resourceTypes: [PHAssetResourceType]
    ) -> Bool {
        guard !hasAdjustments,
              !representsBurst,
              !mediaSubtypes.contains(.photoLive),
              resourceTypes.count == 1 else { return false }

        switch mediaType {
        case .image:
            return resourceTypes[0] == .photo
        case .video:
            return resourceTypes[0] == .video
        case .audio, .unknown:
            return false
        @unknown default:
            return false
        }
    }

    static func eligibleSourceIdentifier(
        _ identifier: String?,
        allowsInspection: Bool,
        assetIsAccessible: Bool,
        providerHasLivePhoto: Bool,
        resourceProfileIsSafe: Bool
    ) -> String? {
        guard allowsInspection,
              let identifier,
              !identifier.isEmpty,
              assetIsAccessible,
              !providerHasLivePhoto,
              resourceProfileIsSafe else { return nil }
        return identifier
    }

    nonisolated func sourceIdentifiers(for checks: [PhotoLibraryDeletionCheck]) async -> [String?] {
        do {
            return try await BlockingWork.run(on: PhotoLibraryService.queryQueue) {
                checks.map { check in
                    PhotoLibraryService.sourceIdentifier(
                        for: check,
                        assetProfile: PhotoLibraryService.libraryAssetProfile(localIdentifier:)
                    )
                }
            }
        } catch {
            return checks.map { _ in nil }
        }
    }

    /// The picker-time rule: PhotoKit is asked only about a non-empty identifier whose provider has no Live Photo.
    static func sourceIdentifier(
        for check: PhotoLibraryDeletionCheck,
        assetProfile: (String) -> PhotoLibraryAssetProfile?
    ) -> String? {
        switch check {
        case .resolved(let identifier):
            return identifier
        case .pending(let identifier, let providerHasLivePhoto):
            var profile: PhotoLibraryAssetProfile?
            if let identifier, !identifier.isEmpty, !providerHasLivePhoto {
                profile = assetProfile(identifier)
            }
            let resourceProfileIsSafe = profile.map { asset in
                isSafeDeletionResourceProfile(
                    mediaType: asset.mediaType,
                    mediaSubtypes: asset.mediaSubtypes,
                    hasAdjustments: asset.hasAdjustments,
                    representsBurst: asset.representsBurst,
                    resourceTypes: asset.resourceTypes
                )
            } ?? false
            return eligibleSourceIdentifier(
                identifier,
                allowsInspection: true,
                assetIsAccessible: profile != nil,
                providerHasLivePhoto: providerHasLivePhoto,
                resourceProfileIsSafe: resourceProfileIsSafe
            )
        }
    }

    /// One fetch by identifier, accepted only when it finds exactly one asset.
    static func libraryAssetProfile(localIdentifier: String) -> PhotoLibraryAssetProfile? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard assets.count == 1 else { return nil }
        let asset = assets.object(at: 0)
        return PhotoLibraryAssetProfile(
            mediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            hasAdjustments: asset.hasAdjustments,
            representsBurst: asset.representsBurst,
            resourceTypes: PHAssetResource.assetResources(for: asset).map(\.type)
        )
    }

    func deleteOriginals(localIdentifiers: [String]) async throws {
        let identifiers = Array(Set(localIdentifiers))
        guard !identifiers.isEmpty else { return }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw VaultError.photosPermissionDenied
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count == identifiers.count else {
            throw status == .limited ? VaultError.limitedPhotosAccess : VaultError.fileOperationFailed
        }
        for index in 0..<assets.count {
            guard Self.isSafeToDeleteAfterRepresentationImport(assets.object(at: index)) else {
                throw VaultError.fileOperationFailed
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? VaultError.fileOperationFailed)
                }
            }
        }
    }
}
