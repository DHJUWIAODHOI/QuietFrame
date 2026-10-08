import Foundation
import ImageIO
import Observation
import UIKit

private let maximumEncryptedPhotoByteCount = 512 * 1_024 * 1_024
private let maximumPhotoPixelSize = 4_096

struct ViewerPhotoRequest: Sendable, Equatable {
    let mediaID: UUID
    let storageIdentifier: String
    let location: EncryptedAssetLocation
}

extension ViewerPhotoRequest {
    @MainActor
    init(media: VaultMedia) {
        self.init(
            mediaID: media.id,
            storageIdentifier: media.storageIdentifier,
            location: media.isTrashed ? .trash : .media
        )
    }
}

/// Decrypts and downsamples viewer photos one at a time, most urgent request first,
/// and keeps only the photos in the current preparation window in memory.
@MainActor
@Observable
final class ViewerPhotoLoader {
    private enum LoadResult: Sendable {
        case loaded(UIImage)
        case failed(String)
        case cancelled
    }

    private(set) var images: [UUID: UIImage] = [:]
    private(set) var failures: [UUID: String] = [:]

    private let storage: any SecureFileStoring
    @ObservationIgnored private var requests: [ViewerPhotoRequest] = []
    @ObservationIgnored private var loadingMediaID: UUID?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(storage: any SecureFileStoring) {
        self.storage = storage
    }

    var isLoading: Bool {
        loadTask != nil
    }

    func image(for mediaID: UUID) -> UIImage? {
        images[mediaID]
    }

    func failureMessage(for mediaID: UUID) -> String? {
        failures[mediaID]
    }

    /// `newRequests` is ordered by urgency; the first request is the selected page.
    func prepare(_ newRequests: [ViewerPhotoRequest]) {
        requests = newRequests
        let wantedIDs = Set(newRequests.map(\.mediaID))
        if images.keys.contains(where: { !wantedIDs.contains($0) }) {
            images = images.filter { wantedIDs.contains($0.key) }
        }
        if failures.keys.contains(where: { !wantedIDs.contains($0) }) {
            failures = failures.filter { wantedIDs.contains($0.key) }
        }
        if let loadingMediaID, shouldInterruptLoad(of: loadingMediaID, wantedIDs: wantedIDs) {
            loadTask?.cancel()
        }
        startNextLoadIfNeeded()
    }

    func releaseAll() {
        requests = []
        images = [:]
        failures = [:]
        loadTask?.cancel()
    }

    private func shouldInterruptLoad(of mediaID: UUID, wantedIDs: Set<UUID>) -> Bool {
        guard wantedIDs.contains(mediaID) else { return true }
        guard let selectedID = requests.first?.mediaID, selectedID != mediaID else { return false }
        return images[selectedID] == nil && failures[selectedID] == nil
    }

    private func startNextLoadIfNeeded() {
        // A cancelled load keeps its slot until it finishes so decodes never overlap.
        guard loadTask == nil,
              let request = requests.first(where: { images[$0.mediaID] == nil && failures[$0.mediaID] == nil })
        else { return }

        loadingMediaID = request.mediaID
        loadTask = Task { [storage, weak self] in
            let result = await ViewerPhotoLoader.load(request, storage: storage)
            await MainActor.run {
                self?.finishLoad(mediaID: request.mediaID, result: result)
            }
        }
    }

    private func finishLoad(mediaID: UUID, result: LoadResult) {
        loadTask = nil
        loadingMediaID = nil
        if requests.contains(where: { $0.mediaID == mediaID }) {
            switch result {
            case .loaded(let image):
                images[mediaID] = image
            case .failed(let message):
                failures[mediaID] = message
            case .cancelled:
                break
            }
        }
        startNextLoadIfNeeded()
    }

    private nonisolated static func load(
        _ request: ViewerPhotoRequest,
        storage: any SecureFileStoring
    ) async -> LoadResult {
        do {
            let data = try await storage.decryptData(
                identifier: request.storageIdentifier,
                location: request.location,
                maximumByteCount: maximumEncryptedPhotoByteCount
            )
            try Task.checkCancellation()
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: maximumPhotoPixelSize,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary
                      ) else { return nil }
                return UIImage(cgImage: image)
            }.value
            guard let decoded else { return .failed(VaultError.corruptedFile.localizedDescription) }
            return .loaded(decoded)
        } catch is CancellationError {
            return .cancelled
        } catch VaultError.importCancelled {
            return .cancelled
        } catch {
            return .failed(
                (error as? VaultError)?.localizedDescription
                    ?? VaultError.corruptedFile.localizedDescription
            )
        }
    }
}
