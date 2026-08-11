import Foundation
import SwiftData

@Model
final class VaultAlbum {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var position: Int = 0
    var coverMediaID: UUID?
    @Relationship(deleteRule: .nullify, inverse: \VaultMedia.album)
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

    var activeMediaCount: Int {
        media.lazy.filter { !$0.isTrashed }.count
    }
}
