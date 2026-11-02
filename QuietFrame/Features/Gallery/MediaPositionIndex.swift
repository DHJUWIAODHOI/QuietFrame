import Foundation

/// Positions in a list of IDs, rebuilt only when the list changes, for callers that look them up on every frame.
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
