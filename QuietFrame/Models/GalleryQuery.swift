import Foundation

struct GalleryQuery: Equatable, Sendable {
    var collection: VaultCollection?
    var albumID: UUID?
    var filter: MediaFilter
    var sort: MediaSortOption
    var searchText: String
    var includesTrash: Bool

    init(
        collection: VaultCollection? = .allMedia,
        albumID: UUID? = nil,
        filter: MediaFilter = .all,
        sort: MediaSortOption = .importedAt,
        searchText: String = "",
        includesTrash: Bool = false
    ) {
        self.collection = collection
        self.albumID = albumID
        self.filter = filter
        self.sort = sort
        self.searchText = searchText
        self.includesTrash = includesTrash
    }
}

enum AlbumDeletionMode: Equatable, Sendable {
    case keepMedia
    case moveMediaToTrash
}
