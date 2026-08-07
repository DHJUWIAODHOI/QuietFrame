import Foundation
import SwiftData

@Model
final class VaultAlbum {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var coverMediaID: UUID?
    @Relationship(deleteRule: .nullify, inverse: \VaultMedia.album)
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

    var activeMediaCount: Int {
        media.lazy.filter { !$0.isTrashed }.count
    }
}
