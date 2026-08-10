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

protocol MediaExporting: Sendable {
    func prepareForSharing(media: [VaultMedia]) async throws -> MediaExportLease
    func saveToPhotos(media: [VaultMedia]) async throws
}

actor MediaExportService: MediaExporting {
    private struct PhotosExportItem: @unchecked Sendable {
        let url: URL
        let mediaType: MediaType
        let creationDate: Date?
    }

    private let storage: any SecureFileStoring
    private let operationGate: VaultOperationGate

    init(
        storage: any SecureFileStoring,
        operationGate: VaultOperationGate = VaultOperationGate()
    ) {
        self.storage = storage
        self.operationGate = operationGate
    }

    func prepareForSharing(media: [VaultMedia]) async throws -> MediaExportLease {
        try await operationGate.withLock {
            try await self.prepareForSharingExclusively(media: media)
        }
    }

    private func prepareForSharingExclusively(media: [VaultMedia]) async throws -> MediaExportLease {
        guard !media.isEmpty else { throw VaultError.invalidInput("Select at least one item to export.") }
        var files: [SecureTemporaryFileLease] = []
        do {
            for item in media {
                try Task.checkCancellation()
                let fileExtension = UTType(item.contentTypeIdentifier)?.preferredFilenameExtension
                let lease = try await storage.temporaryDecryptedFile(
                    identifier: item.storageIdentifier,
                    location: item.isTrashed ? .trash : .media,
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

    func saveToPhotos(media: [VaultMedia]) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw VaultError.photosPermissionDenied
        }
        try await operationGate.withLock {
            let lease = try await prepareForSharingExclusively(media: media)
            defer { lease.cleanup() }
            let exportItems = zip(media, lease.urls).map { item, url in
                PhotosExportItem(url: url, mediaType: item.mediaType, creationDate: item.originalCreationDate)
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
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? VaultError.exportFailed)
                    }
                }
            }
        }
    }
}
