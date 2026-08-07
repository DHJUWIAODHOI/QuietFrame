import Foundation
import SwiftData

@Model
final class VaultMedia {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var storageIdentifier: String
    @Attribute(.unique) var contentFingerprint: String
    var thumbnailIdentifier: String?
    var mediaTypeRawValue: String
    var contentTypeIdentifier: String
    var originalFilename: String?
    var importedAt: Date
    var originalCreationDate: Date?
    var modifiedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: TimeInterval?
    var byteCount: Int64
    var isFavorite: Bool
    var tags: [String]
    var trashedAt: Date?
    var previousAlbumID: UUID?
    var album: VaultAlbum?

    init(
        id: UUID = UUID(),
        storageIdentifier: String,
        contentFingerprint: String,
        thumbnailIdentifier: String? = nil,
        metadata: MediaMetadata,
        importedAt: Date = Date(),
        isFavorite: Bool = false,
        tags: [String] = [],
        album: VaultAlbum? = nil
    ) {
        self.id = id
        self.storageIdentifier = storageIdentifier
        self.contentFingerprint = contentFingerprint
        self.thumbnailIdentifier = thumbnailIdentifier
        self.mediaTypeRawValue = metadata.mediaType.rawValue
        self.contentTypeIdentifier = metadata.contentTypeIdentifier
        self.originalFilename = metadata.originalFilename
        self.importedAt = importedAt
        self.originalCreationDate = metadata.originalCreationDate
        self.modifiedAt = importedAt
        self.pixelWidth = metadata.pixelWidth
        self.pixelHeight = metadata.pixelHeight
        self.duration = metadata.duration
        self.byteCount = metadata.byteCount
        self.isFavorite = isFavorite
        self.tags = tags
        self.album = album
    }

    var mediaType: MediaType {
        MediaType(rawValue: mediaTypeRawValue) ?? .photo
    }

    var displayName: String {
        guard let originalFilename, !originalFilename.isEmpty else {
            return mediaType == .photo ? "Private Photo" : "Private Video"
        }
        return originalFilename
    }

    var isTrashed: Bool { trashedAt != nil }

    var accessibilitySummary: String {
        var parts = [displayName, mediaType == .photo ? "Photo" : "Video"]
        if isFavorite { parts.append("favorite") }
        parts.append(importedAt.formatted(date: .abbreviated, time: .omitted))
        if let album { parts.append("album \(album.name)") }
        if let duration, mediaType == .video {
            let seconds = max(0, Int(duration.rounded()))
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return parts.joined(separator: ", ")
    }
}
