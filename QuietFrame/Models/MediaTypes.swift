import Foundation

enum MediaType: String, Codable, CaseIterable, Identifiable, Sendable {
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "Photos"
        case .video: "Videos"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        }
    }
}

enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case photos
    case videos
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .favorites: "Favorites"
        }
    }
}

enum MediaSortOption: String, CaseIterable, Identifiable, Sendable {
    case importedAt
    case createdAt
    case name
    case size
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importedAt: "Date Imported"
        case .createdAt: "Date Created"
        case .name: "Name"
        case .size: "Size"
        case .type: "Type"
        }
    }
}

enum VaultCollection: String, CaseIterable, Identifiable, Sendable {
    case allMedia
    case recentlyAdded
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allMedia: "All Media"
        case .recentlyAdded: "Recently Added"
        case .favorites: "Favorites"
        }
    }

    var symbolName: String {
        switch self {
        case .allMedia: "rectangle.stack.fill"
        case .recentlyAdded: "clock.fill"
        case .favorites: "heart.fill"
        }
    }
}

struct MediaMetadata: Sendable, Equatable {
    let mediaType: MediaType
    let contentTypeIdentifier: String
    let originalFilename: String?
    let originalCreationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval?
    let byteCount: Int64
}
