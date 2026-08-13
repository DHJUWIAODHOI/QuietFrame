import Foundation
import SwiftData

enum VaultSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

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
            mediaTypeRawValue: String = "photo",
            contentTypeIdentifier: String = "public.jpeg",
            originalFilename: String? = nil,
            importedAt: Date = Date(),
            originalCreationDate: Date? = nil,
            pixelWidth: Int = 0,
            pixelHeight: Int = 0,
            duration: TimeInterval? = nil,
            byteCount: Int64 = 0,
            isFavorite: Bool = false,
            tags: [String] = [],
            trashedAt: Date? = nil,
            previousAlbumID: UUID? = nil,
            album: VaultAlbum? = nil
        ) {
            self.id = id
            self.storageIdentifier = storageIdentifier
            self.contentFingerprint = contentFingerprint
            self.thumbnailIdentifier = thumbnailIdentifier
            self.mediaTypeRawValue = mediaTypeRawValue
            self.contentTypeIdentifier = contentTypeIdentifier
            self.originalFilename = originalFilename
            self.importedAt = importedAt
            self.originalCreationDate = originalCreationDate
            self.modifiedAt = importedAt
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.duration = duration
            self.byteCount = byteCount
            self.isFavorite = isFavorite
            self.tags = tags
            self.trashedAt = trashedAt
            self.previousAlbumID = previousAlbumID
            self.album = album
        }
    }

    @Model
    final class VaultAlbum {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        var modifiedAt: Date
        var coverMediaID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \VaultSchemaV1.VaultMedia.album)
        var media: [VaultMedia]

        init(
            id: UUID = UUID(),
            name: String,
            createdAt: Date = Date(),
            coverMediaID: UUID? = nil
        ) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.modifiedAt = createdAt
            self.coverMediaID = coverMediaID
            self.media = []
        }
    }

    @Model
    final class AppSettings {
        @Attribute(.unique) var singletonKey: String
        var biometricsEnabled: Bool
        var autoLockSeconds: Int
        var trashRetentionDays: Int
        var appearanceRawValue: String
        var thumbnailSizeRawValue: String
        var albumSortRawValue: String
        var createdAt: Date
        var modifiedAt: Date

        init(
            singletonKey: String = "primary",
            biometricsEnabled: Bool = false,
            autoLockSeconds: Int = 0,
            trashRetentionDays: Int = 30,
            appearanceRawValue: String = "system",
            thumbnailSizeRawValue: String = "comfortable",
            albumSortRawValue: String = "modifiedDate",
            createdAt: Date = Date()
        ) {
            self.singletonKey = singletonKey
            self.biometricsEnabled = biometricsEnabled
            self.autoLockSeconds = autoLockSeconds
            self.trashRetentionDays = trashRetentionDays
            self.appearanceRawValue = appearanceRawValue
            self.thumbnailSizeRawValue = thumbnailSizeRawValue
            self.albumSortRawValue = albumSortRawValue
            self.createdAt = createdAt
            self.modifiedAt = createdAt
        }
    }

    @Model
    final class ImportRecord {
        @Attribute(.unique) var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var requestedCount: Int
        var importedCount: Int
        var duplicateCount: Int
        var failedCount: Int
        var statusRawValue: String

        init(id: UUID = UUID(), requestedCount: Int, startedAt: Date = Date()) {
            self.id = id
            self.startedAt = startedAt
            self.finishedAt = nil
            self.requestedCount = requestedCount
            self.importedCount = 0
            self.duplicateCount = 0
            self.failedCount = 0
            self.statusRawValue = "running"
        }
    }

    static var models: [any PersistentModel.Type] {
        [VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self]
    }
}

enum VaultSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

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
            mediaTypeRawValue: String = "photo",
            contentTypeIdentifier: String = "public.jpeg",
            originalFilename: String? = nil,
            importedAt: Date = Date(),
            originalCreationDate: Date? = nil,
            pixelWidth: Int = 0,
            pixelHeight: Int = 0,
            duration: TimeInterval? = nil,
            byteCount: Int64 = 0,
            isFavorite: Bool = false,
            tags: [String] = [],
            trashedAt: Date? = nil,
            previousAlbumID: UUID? = nil,
            album: VaultAlbum? = nil
        ) {
            self.id = id
            self.storageIdentifier = storageIdentifier
            self.contentFingerprint = contentFingerprint
            self.thumbnailIdentifier = thumbnailIdentifier
            self.mediaTypeRawValue = mediaTypeRawValue
            self.contentTypeIdentifier = contentTypeIdentifier
            self.originalFilename = originalFilename
            self.importedAt = importedAt
            self.originalCreationDate = originalCreationDate
            self.modifiedAt = importedAt
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.duration = duration
            self.byteCount = byteCount
            self.isFavorite = isFavorite
            self.tags = tags
            self.trashedAt = trashedAt
            self.previousAlbumID = previousAlbumID
            self.album = album
        }
    }

    @Model
    final class VaultAlbum {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        var modifiedAt: Date
        var position: Int = 0
        var coverMediaID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \VaultSchemaV2.VaultMedia.album)
        var media: [VaultMedia]

        init(
            id: UUID = UUID(),
            name: String,
            createdAt: Date = Date(),
            position: Int = 0,
            coverMediaID: UUID? = nil
        ) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.modifiedAt = createdAt
            self.position = position
            self.coverMediaID = coverMediaID
            self.media = []
        }
    }

    @Model
    final class AppSettings {
        @Attribute(.unique) var singletonKey: String
        var biometricsEnabled: Bool
        var autoLockSeconds: Int
        var trashRetentionDays: Int
        var appearanceRawValue: String
        var thumbnailSizeRawValue: String
        var albumSortRawValue: String
        var createdAt: Date
        var modifiedAt: Date

        init(
            singletonKey: String = "primary",
            biometricsEnabled: Bool = false,
            autoLockSeconds: Int = 0,
            trashRetentionDays: Int = 30,
            appearanceRawValue: String = "system",
            thumbnailSizeRawValue: String = "comfortable",
            albumSortRawValue: String = "modifiedDate",
            createdAt: Date = Date()
        ) {
            self.singletonKey = singletonKey
            self.biometricsEnabled = biometricsEnabled
            self.autoLockSeconds = autoLockSeconds
            self.trashRetentionDays = trashRetentionDays
            self.appearanceRawValue = appearanceRawValue
            self.thumbnailSizeRawValue = thumbnailSizeRawValue
            self.albumSortRawValue = albumSortRawValue
            self.createdAt = createdAt
            self.modifiedAt = createdAt
        }
    }

    @Model
    final class ImportRecord {
        @Attribute(.unique) var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var requestedCount: Int
        var importedCount: Int
        var duplicateCount: Int
        var failedCount: Int
        var statusRawValue: String

        init(id: UUID = UUID(), requestedCount: Int, startedAt: Date = Date()) {
            self.id = id
            self.startedAt = startedAt
            self.finishedAt = nil
            self.requestedCount = requestedCount
            self.importedCount = 0
            self.duplicateCount = 0
            self.failedCount = 0
            self.statusRawValue = "running"
        }
    }

    static var models: [any PersistentModel.Type] {
        [VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self]
    }
}

enum VaultSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self]
    }
}

enum VaultMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [VaultSchemaV1.self, VaultSchemaV2.self, VaultSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: VaultSchemaV1.self, toVersion: VaultSchemaV2.self),
            .lightweight(fromVersion: VaultSchemaV2.self, toVersion: VaultSchemaV3.self)
        ]
    }
}
