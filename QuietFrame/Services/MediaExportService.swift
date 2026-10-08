import Foundation
import Photos
import UniformTypeIdentifiers

final class MediaExportLease: Identifiable, @unchecked Sendable {
    let id = UUID()
    let files: [SecureTemporaryFileLease]

    var urls: [URL] { files.map(\.url) }

    init(files: [SecureTemporaryFileLease]) {
        self.files = files
    }

    func cleanup() {
        files.forEach { $0.cleanup() }
    }

    deinit {
        cleanup()
    }
}

struct MediaExportItem: Sendable, Equatable {
    let storageIdentifier: String
    let location: EncryptedAssetLocation
    let contentTypeIdentifier: String
    let mediaType: MediaType
    let creationDate: Date?
}

extension MediaExportItem {
    @MainActor
    init(media: VaultMedia) {
        self.init(
            storageIdentifier: media.storageIdentifier,
            location: media.isTrashed ? .trash : .media,
            contentTypeIdentifier: media.contentTypeIdentifier,
            mediaType: media.mediaType,
            creationDate: media.originalCreationDate
        )
    }
}

protocol MediaExporting: Sendable {
    func prepareForSharing(mediaIDs: [UUID]) async throws -> MediaExportLease
    func saveToPhotos(mediaIDs: [UUID]) async throws
}

actor MediaExportService: MediaExporting {
    private struct PhotosExportItem: Sendable {
        let url: URL
        let mediaType: MediaType
        let creationDate: Date?
    }

    private let storage: any SecureFileStoring
    private let repository: any VaultRepositoryProtocol
    private let operationGate: VaultOperationGate

    init(
        storage: any SecureFileStoring,
        repository: any VaultRepositoryProtocol,
        operationGate: VaultOperationGate = VaultOperationGate()
    ) {
        self.storage = storage
        self.repository = repository
        self.operationGate = operationGate
    }

    func prepareForSharing(mediaIDs: [UUID]) async throws -> MediaExportLease {
        try Self.validateSelection(mediaIDs)
        return try await operationGate.withLock {
            let items = try await self.repository.exportItems(ids: mediaIDs)
            return try await self.prepareForSharingExclusively(items: items)
        }
    }

    private static func validateSelection(_ mediaIDs: [UUID]) throws {
        guard !mediaIDs.isEmpty else { throw VaultError.invalidInput("Select at least one item to export.") }
    }

    private func prepareForSharingExclusively(items: [MediaExportItem]) async throws -> MediaExportLease {
        var files: [SecureTemporaryFileLease] = []
        do {
            for item in items {
                try Task.checkCancellation()
                let fileExtension = UTType(item.contentTypeIdentifier)?.preferredFilenameExtension
                let lease = try await storage.temporaryDecryptedFile(
                    identifier: item.storageIdentifier,
                    location: item.location,
                    preferredExtension: fileExtension
                )
                files.append(lease)
            }
            return MediaExportLease(files: files)
        } catch is CancellationError {
            files.forEach { $0.cleanup() }
            throw VaultError.exportFailed
        } catch {
            files.forEach { $0.cleanup() }
            throw error
        }
    }

    func saveToPhotos(mediaIDs: [UUID]) async throws {
        try Self.validateSelection(mediaIDs)
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw VaultError.photosPermissionDenied
        }
        try await operationGate.withLock {
            let items = try await self.repository.exportItems(ids: mediaIDs)
            let lease = try await self.prepareForSharingExclusively(items: items)
            defer { lease.cleanup() }
            let exportItems = zip(items, lease.urls).map { item, url in
                PhotosExportItem(url: url, mediaType: item.mediaType, creationDate: item.creationDate)
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    for item in exportItems {
                        let request = PHAssetCreationRequest.forAsset()
                        request.creationDate = item.creationDate
                        request.addResource(
                            with: item.mediaType == .photo ? .photo : .video,
                            fileURL: item.url,
                            options: nil
                        )
                    }
                } completionHandler: { success, error in
                    continuation.resume(with: success ? .success(()) : .failure(error ?? VaultError.exportFailed))
                }
            }
        }
    }
}
