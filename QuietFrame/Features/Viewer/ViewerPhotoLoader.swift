import Foundation
import ImageIO
import Observation
import UIKit

private let maximumEncryptedPhotoByteCount = 512 * 1_024 * 1_024

struct ViewerPhotoRequest: Sendable, Equatable {
    /// The decode size for a zoomed photo, and for any photo whose display size is unknown.
    static let zoomPixelSize = 4_096

    let mediaID: UUID
    let storageIdentifier: String
    let location: EncryptedAssetLocation
    /// The longest side to decode to.
    var pixelSize = ViewerPhotoRequest.zoomPixelSize
}

extension ViewerPhotoRequest {
    @MainActor
    init(media: VaultMedia, pixelSize: Int = ViewerPhotoRequest.zoomPixelSize) {
        self.init(
            mediaID: media.id,
            storageIdentifier: media.storageIdentifier,
            location: media.isTrashed ? .trash : .media,
            pixelSize: pixelSize
        )
    }
}

/// The longest side a photo needs to fill a viewer at zoom scale 1, in either device orientation and whichever way
/// its EXIF orientation turns it, so rotating never needs a new decode. Unknown sizes decode at the zoom size.
func viewerFitPixelSize(photoPixelSize: CGSize, viewerPixelSize: CGSize) -> Int {
    let photoLong = max(photoPixelSize.width, photoPixelSize.height)
    let photoShort = min(photoPixelSize.width, photoPixelSize.height)
    let viewerLong = max(viewerPixelSize.width, viewerPixelSize.height)
    let viewerShort = min(viewerPixelSize.width, viewerPixelSize.height)
    guard photoShort > 0, viewerShort > 0, photoLong.isFinite, viewerLong.isFinite else {
        return ViewerPhotoRequest.zoomPixelSize
    }
    let fitted = max(min(viewerLong, viewerShort * photoLong / photoShort), viewerShort)
    let pixels = Int(min(fitted, photoLong).rounded(.up))
    return min(max(pixels, 1), ViewerPhotoRequest.zoomPixelSize)
}

/// The longest side to decode a photo to. A zoomed photo decodes again at the zoom size, unless its fitted size
/// already shows every pixel it has.
func viewerPhotoPixelSize(photoPixelSize: CGSize, viewerPixelSize: CGSize, isZoomed: Bool) -> Int {
    let fitted = viewerFitPixelSize(photoPixelSize: photoPixelSize, viewerPixelSize: viewerPixelSize)
    guard isZoomed, CGFloat(fitted) < max(photoPixelSize.width, photoPixelSize.height) else { return fitted }
    return ViewerPhotoRequest.zoomPixelSize
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
    @ObservationIgnored private var selectedMediaID: UUID?
    @ObservationIgnored private var loadedPixelSizes: [UUID: Int] = [:]
    @ObservationIgnored private var failedShrinks: Set<UUID> = []
    @ObservationIgnored private var loadingMediaID: UUID?
    @ObservationIgnored private var loadingPixelSize = 0
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

    /// `newRequests` is ordered by urgency. The first request is the selected page unless `firstIsSelected` is
    /// false, as when the selected page is a video. A photo already decoded at least as large as its request is
    /// kept; a larger request decodes it again and swaps the sharper copy in. A zoomed copy of a photo that is no
    /// longer selected keeps showing until a display-size copy replaces it.
    func prepare(_ newRequests: [ViewerPhotoRequest], firstIsSelected: Bool = true) {
        requests = newRequests
        selectedMediaID = firstIsSelected ? newRequests.first?.mediaID : nil
        let wantedIDs = Set(newRequests.map(\.mediaID))
        if images.keys.contains(where: { !wantedIDs.contains($0) }) {
            images = images.filter { wantedIDs.contains($0.key) }
            loadedPixelSizes = loadedPixelSizes.filter { wantedIDs.contains($0.key) }
        }
        if failures.keys.contains(where: { !wantedIDs.contains($0) }) {
            failures = failures.filter { wantedIDs.contains($0.key) }
        }
        failedShrinks.formIntersection(wantedIDs)
        if let loadingMediaID, shouldInterruptLoad(of: loadingMediaID, pixelSize: loadingPixelSize, wantedIDs: wantedIDs) {
            loadTask?.cancel()
        }
        startNextLoadIfNeeded()
    }

    func releaseAll() {
        requests = []
        selectedMediaID = nil
        images = [:]
        failures = [:]
        loadedPixelSizes = [:]
        failedShrinks = []
        loadTask?.cancel()
    }

    private func needsLoad(_ request: ViewerPhotoRequest) -> Bool {
        guard failures[request.mediaID] == nil else { return false }
        guard images[request.mediaID] != nil, let loadedPixelSize = loadedPixelSizes[request.mediaID] else { return true }
        return loadedPixelSize < request.pixelSize || keepsOversizedCopy(request)
    }

    /// A page left after zooming still holds its zoomed copy, which is decoded again at display size.
    private func keepsOversizedCopy(_ request: ViewerPhotoRequest) -> Bool {
        guard request.mediaID != selectedMediaID,
              !failedShrinks.contains(request.mediaID),
              let image = images[request.mediaID]?.cgImage else { return false }
        return Double(max(image.width, image.height)) > Double(request.pixelSize) * 1.25
    }

    private func shouldInterruptLoad(of mediaID: UUID, pixelSize: Int, wantedIDs: Set<UUID>) -> Bool {
        guard wantedIDs.contains(mediaID) else { return true }
        if images[mediaID] != nil, let request = requests.first(where: { $0.mediaID == mediaID }) {
            let loadedPixelSize = loadedPixelSizes[mediaID, default: 0]
            // A sharper copy that is no longer wanted, or a smaller copy of a photo that is selected again.
            if pixelSize > request.pixelSize, request.pixelSize <= loadedPixelSize { return true }
            if pixelSize < loadedPixelSize, !keepsOversizedCopy(request) { return true }
        }
        guard let selectedID = selectedMediaID, selectedID != mediaID else { return false }
        return images[selectedID] == nil && failures[selectedID] == nil
    }

    private func startNextLoadIfNeeded() {
        // A cancelled load keeps its slot until it finishes so decodes never overlap.
        guard loadTask == nil, let request = requests.first(where: needsLoad) else { return }

        loadingMediaID = request.mediaID
        loadingPixelSize = request.pixelSize
        loadTask = Task { [storage, weak self] in
            let result = await ViewerPhotoLoader.load(request, storage: storage)
            await MainActor.run {
                self?.finishLoad(request: request, result: result)
            }
        }
    }

    private func finishLoad(request: ViewerPhotoRequest, result: LoadResult) {
        loadTask = nil
        loadingMediaID = nil
        loadingPixelSize = 0
        let mediaID = request.mediaID
        if let wanted = requests.first(where: { $0.mediaID == mediaID }) {
            let loadedPixelSize = loadedPixelSizes[mediaID, default: 0]
            switch result {
            case .loaded(let image):
                // A sharper copy replaces the shown one only while it is still wanted, and a display-size copy
                // replaces a zoomed copy the page no longer needs.
                if images[mediaID] == nil
                    || (request.pixelSize > loadedPixelSize && wanted.pixelSize > loadedPixelSize)
                    || (request.pixelSize == wanted.pixelSize && keepsOversizedCopy(wanted)) {
                    images[mediaID] = image
                    loadedPixelSizes[mediaID] = request.pixelSize
                }
            case .failed(let message):
                if images[mediaID] == nil {
                    failures[mediaID] = message
                } else if request.pixelSize < loadedPixelSize {
                    // The zoomed copy keeps showing; a failed smaller copy is not retried.
                    failedShrinks.insert(mediaID)
                } else {
                    // The photo still shows at its current size; a failed sharper copy is not retried.
                    loadedPixelSizes[mediaID] = max(loadedPixelSize, request.pixelSize)
                }
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
            let pixelSize = request.pixelSize
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
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
