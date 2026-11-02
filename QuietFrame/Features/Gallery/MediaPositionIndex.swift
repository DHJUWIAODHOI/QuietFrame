import Foundation

/// Positions of media in a list by ID. A lookup that finds the index out of date rebuilds it once, so callers that
/// look up positions on every frame never scan the whole list.
@MainActor
final class MediaPositionIndex {
    private var positions: [UUID: Int] = [:]

    func index(of id: UUID, in items: [VaultMedia]) -> Int? {
        if let index = positions[id], items.indices.contains(index), items[index].id == id {
            return index
        }
        var rebuilt: [UUID: Int] = [:]
        rebuilt.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where rebuilt[item.id] == nil {
            rebuilt[item.id] = index
        }
        positions = rebuilt
        return rebuilt[id]
    }
}
