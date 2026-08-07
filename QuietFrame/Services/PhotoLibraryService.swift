import Foundation
import Photos

protocol PhotoLibraryServing: Sendable {
    func deleteOriginals(localIdentifiers: [String]) async throws
}

actor PhotoLibraryService: PhotoLibraryServing {
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
