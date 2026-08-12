import Foundation
import Photos

enum PhotoLibraryImportAccess: Equatable, Sendable {
    case full
    case limited
    case denied
}

protocol PhotoLibraryServing: Sendable {
    func requestImportAccess() async -> PhotoLibraryImportAccess
    func deleteOriginals(localIdentifiers: [String]) async throws
}

actor PhotoLibraryService: PhotoLibraryServing {
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
