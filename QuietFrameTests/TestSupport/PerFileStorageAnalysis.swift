import Foundation
import SwiftData
@testable import QuietFrame

/// Storage analysis as it worked before the bulk listing: one size call per file and the largest items sorted over
/// the models. Tests and benchmarks hold the service to its results and errors.
enum PerFileStorageAnalysis {
    @MainActor
    static func summary(context: ModelContext, storage: any SecureFileStoring) async throws -> StorageSummary {
        let media = try context.fetch(FetchDescriptor<VaultMedia>())
        let albumCount = try context.fetchCount(FetchDescriptor<VaultAlbum>())
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
