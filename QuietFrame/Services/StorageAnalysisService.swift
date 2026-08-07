import Foundation
import SwiftData

struct LargeMediaItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let mediaType: MediaType
    let byteCount: Int64
}

struct StorageSummary: Sendable, Equatable {
    let totalEncryptedBytes: Int64
    let photoBytes: Int64
    let videoBytes: Int64
    let thumbnailBytes: Int64
    let trashBytes: Int64
    let mediaCount: Int
    let albumCount: Int
    let largestItems: [LargeMediaItem]
}

@MainActor
protocol StorageAnalyzing: AnyObject {
    func analyze() async throws -> StorageSummary
}

@MainActor
final class StorageAnalysisService: StorageAnalyzing {
    private let modelContext: ModelContext
    private let storage: any SecureFileStoring

    init(modelContext: ModelContext, storage: any SecureFileStoring) {
        self.modelContext = modelContext
        self.storage = storage
    }

    func analyze() async throws -> StorageSummary {
        let media = try modelContext.fetch(FetchDescriptor<VaultMedia>())
        let albumCount = try modelContext.fetchCount(FetchDescriptor<VaultAlbum>())
        var photoBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var thumbnailBytes: Int64 = 0
        var trashBytes: Int64 = 0

        for item in media {
            let location: EncryptedAssetLocation = item.isTrashed ? .trash : .media
            let encryptedBytes = try await storage.fileByteCount(
                identifier: item.storageIdentifier,
                location: location
            )
            if item.isTrashed {
                trashBytes += encryptedBytes
            } else if item.mediaType == .photo {
                photoBytes += encryptedBytes
            } else {
                videoBytes += encryptedBytes
            }
            if let thumbnailIdentifier = item.thumbnailIdentifier {
                thumbnailBytes += try await storage.fileByteCount(
                    identifier: thumbnailIdentifier,
                    location: .thumbnails
                )
            }
        }

        let largest = media
            .filter { !$0.isTrashed }
            .sorted { $0.byteCount > $1.byteCount }
            .prefix(20)
            .map {
                LargeMediaItem(
                    id: $0.id,
                    name: $0.displayName,
                    mediaType: $0.mediaType,
                    byteCount: $0.byteCount
                )
            }

        return StorageSummary(
            totalEncryptedBytes: photoBytes + videoBytes + trashBytes + thumbnailBytes,
            photoBytes: photoBytes,
            videoBytes: videoBytes,
            thumbnailBytes: thumbnailBytes,
            trashBytes: trashBytes,
            mediaCount: media.count,
            albumCount: albumCount,
            largestItems: Array(largest)
        )
    }
}
