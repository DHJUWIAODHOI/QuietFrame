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
        var descriptor = FetchDescriptor<VaultMedia>()
        descriptor.propertiesToFetch = [
            \.id,
            \.storageIdentifier,
            \.thumbnailIdentifier,
            \.trashedAt,
            \.mediaTypeRawValue,
            \.byteCount,
            \.originalFilename
        ]
        let media = try modelContext.fetch(descriptor)
        let albumCount = try modelContext.fetchCount(FetchDescriptor<VaultAlbum>())
        let files = media.map(MediaFiles.init)

        var mediaSizes: [String: Int64] = [:]
        var trashSizes: [String: Int64] = [:]
        var thumbnailSizes: [String: Int64] = [:]
        if files.contains(where: { !$0.isTrashed }) {
            mediaSizes = await listedByteCounts(in: .media)
        }
        if files.contains(where: { $0.isTrashed }) {
            trashSizes = await listedByteCounts(in: .trash)
        }
        if files.contains(where: { $0.thumbnailIdentifier != nil }) {
            thumbnailSizes = await listedByteCounts(in: .thumbnails)
        }

        var photoBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var thumbnailBytes: Int64 = 0
        var trashBytes: Int64 = 0

        for file in files {
            if file.isTrashed {
                let encryptedBytes = try await byteCount(of: file.storageIdentifier, in: .trash, listed: trashSizes)
                trashBytes += encryptedBytes
            } else {
                let encryptedBytes = try await byteCount(of: file.storageIdentifier, in: .media, listed: mediaSizes)
                if file.mediaType == .photo {
                    photoBytes += encryptedBytes
                } else {
                    videoBytes += encryptedBytes
                }
            }
            if let thumbnailIdentifier = file.thumbnailIdentifier {
                let encryptedBytes = try await byteCount(
                    of: thumbnailIdentifier,
                    in: .thumbnails,
                    listed: thumbnailSizes
                )
                thumbnailBytes += encryptedBytes
            }
        }

        // Ties keep fetch order, as the stable sort over the models did.
        let activeIndices = files.indices.filter { !files[$0].isTrashed }
        let largestIndices = activeIndices.sorted { lhs, rhs in
            let lhsBytes = files[lhs].byteCount
            let rhsBytes = files[rhs].byteCount
            if lhsBytes != rhsBytes {
                return lhsBytes > rhsBytes
            }
            return lhs < rhs
        }.prefix(20)
        let largest = largestIndices.map { index in
            LargeMediaItem(
                id: media[index].id,
                name: media[index].displayName,
                mediaType: files[index].mediaType,
                byteCount: files[index].byteCount
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
            largestItems: largest
        )
    }

    /// A failed listing measures that location's files one by one, as before.
    private func listedByteCounts(in location: EncryptedAssetLocation) async -> [String: Int64] {
        do {
            return try await storage.fileByteCounts(location: location)
        } catch {
            return [:]
        }
    }

    /// A file the listing did not report is measured on its own, so a missing file fails with the same error.
    private func byteCount(
        of identifier: String,
        in location: EncryptedAssetLocation,
        listed: [String: Int64]
    ) async throws -> Int64 {
        if let size = listed[identifier] {
            return size
        }
        return try await storage.fileByteCount(identifier: identifier, location: location)
    }
}

/// The columns the analysis reads, copied out of the models once.
private struct MediaFiles {
    let storageIdentifier: String
    let thumbnailIdentifier: String?
    let isTrashed: Bool
    let mediaType: MediaType
    let byteCount: Int64

    init(_ media: VaultMedia) {
        storageIdentifier = media.storageIdentifier
        thumbnailIdentifier = media.thumbnailIdentifier
        isTrashed = media.isTrashed
        mediaType = media.mediaType
        byteCount = media.byteCount
    }
}
