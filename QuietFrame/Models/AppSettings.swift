import Foundation
import SwiftData

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
        autoLockPeriod: AutoLockPeriod = .immediately,
        trashRetentionPeriod: TrashRetentionPeriod = .thirtyDays,
        appearance: AppAppearance = .system,
        thumbnailSize: ThumbnailSize = .comfortable,
        albumSort: AlbumSortOption = .modifiedDate
    ) {
        self.singletonKey = singletonKey
        self.biometricsEnabled = biometricsEnabled
        self.autoLockSeconds = autoLockPeriod.rawValue
        self.trashRetentionDays = trashRetentionPeriod.rawValue
        self.appearanceRawValue = appearance.rawValue
        self.thumbnailSizeRawValue = thumbnailSize.rawValue
        self.albumSortRawValue = albumSort.rawValue
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    var autoLockPeriod: AutoLockPeriod {
        get { AutoLockPeriod(rawValue: autoLockSeconds) ?? .immediately }
        set { autoLockSeconds = newValue.rawValue; modifiedAt = Date() }
    }

    var trashRetentionPeriod: TrashRetentionPeriod {
        get { TrashRetentionPeriod(rawValue: trashRetentionDays) ?? .thirtyDays }
        set { trashRetentionDays = newValue.rawValue; modifiedAt = Date() }
    }

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: appearanceRawValue) ?? .system }
        set { appearanceRawValue = newValue.rawValue; modifiedAt = Date() }
    }

    var thumbnailSize: ThumbnailSize {
        get { ThumbnailSize(rawValue: thumbnailSizeRawValue) ?? .comfortable }
        set { thumbnailSizeRawValue = newValue.rawValue; modifiedAt = Date() }
    }

    var albumSort: AlbumSortOption {
        get { AlbumSortOption(rawValue: albumSortRawValue) ?? .modifiedDate }
        set { albumSortRawValue = newValue.rawValue; modifiedAt = Date() }
    }
}
