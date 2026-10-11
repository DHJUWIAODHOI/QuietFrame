import Foundation

/// Which reviewed import items are selected, and which album each item is assigned to.
/// Items without an assignment go to the import's default destination.
struct ImportAlbumAssignments: Equatable {
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var albumIDs: [UUID: UUID] = [:]
    /// The items changed by the most recent `assignSelection(to:)`.
    private(set) var lastAssignedIDs: Set<UUID> = []

    var hasSelection: Bool { !selectedIDs.isEmpty }
    var hasAssignments: Bool { !albumIDs.isEmpty }

    func isSelected(_ itemID: UUID) -> Bool {
        selectedIDs.contains(itemID)
    }

    func albumID(for itemID: UUID) -> UUID? {
        albumIDs[itemID]
    }

    func destination(for itemID: UUID, defaultAlbumID: UUID?) -> UUID? {
        albumIDs[itemID] ?? defaultAlbumID
    }

    /// The album shared by every selected item, or nil when they differ or have none.
    var selectionAlbumID: UUID? {
        let albums = Set(selectedIDs.map { albumIDs[$0] })
        guard albums.count == 1, let album = albums.first else { return nil }
        return album
    }

    mutating func toggleSelection(_ itemID: UUID) {
        if selectedIDs.contains(itemID) {
            selectedIDs.remove(itemID)
        } else {
            selectedIDs.insert(itemID)
        }
    }

    mutating func select(_ itemIDs: [UUID]) {
        selectedIDs.formUnion(itemIDs)
    }

    mutating func clearSelection() {
        selectedIDs.removeAll()
    }

    /// Assigns every selected item to `albumID` (nil returns them to the default destination)
    /// and ends the selection so the next group can be picked.
    mutating func assignSelection(to albumID: UUID?) {
        for itemID in selectedIDs {
            albumIDs[itemID] = albumID
        }
        lastAssignedIDs = selectedIDs
        selectedIDs.removeAll()
    }

    mutating func remove(_ itemID: UUID) {
        selectedIDs.remove(itemID)
        albumIDs[itemID] = nil
        lastAssignedIDs.remove(itemID)
    }

    /// Drops assignments to albums that no longer exist, so those items fall back to the default.
    mutating func discardAlbums(notIn existingAlbumIDs: Set<UUID>) {
        albumIDs = albumIDs.filter { existingAlbumIDs.contains($0.value) }
    }

    mutating func reset() {
        selectedIDs.removeAll()
        albumIDs.removeAll()
        lastAssignedIDs.removeAll()
    }
}
