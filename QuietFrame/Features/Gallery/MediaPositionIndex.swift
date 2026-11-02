import Foundation

/// Positions of media in a list of IDs. The map is rebuilt only when the list changes, so callers that look up
/// positions on every frame never scan the whole list, not even for an ID that is missing from it.
@MainActor
final class MediaPositionIndex {
    private var indexedIDs: [UUID] = []
    private var positions: [UUID: Int] = [:]

    func index(of id: UUID, in ids: [UUID]) -> Int? {
        if ids != indexedIDs {
            var rebuilt: [UUID: Int] = [:]
            rebuilt.reserveCapacity(ids.count)
            for (index, mediaID) in ids.enumerated() where rebuilt[mediaID] == nil {
                rebuilt[mediaID] = index
            }
            positions = rebuilt
        }
        // Holding the caller's own array makes the next comparison a check of the same storage.
        indexedIDs = ids
        return positions[id]
    }
}
