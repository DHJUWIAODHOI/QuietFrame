import Foundation
import Observation
import SwiftData

/// The Albums tab's item counts, counted by the store instead of loading every item into memory.
@MainActor
@Observable
final class AlbumCounts {
    private(set) var allCount = 0
    private(set) var recentCount = 0
    private(set) var favoriteCount = 0
    private(set) var albumCounts: [UUID: Int] = [:]
    @ObservationIgnored private var screenIsVisible = false

    func count(forAlbum albumID: UUID) -> Int {
        albumCounts[albumID] ?? 0
    }

    /// Counts on every appearance, not only after a skipped change: Recently Added moves with the clock, and not
    /// every edit (reconciliation, for one) moves the library change counter.
    func screenDidAppear(in context: ModelContext, albumIDs: [UUID], now: Date = Date()) {
        screenIsVisible = true
        refresh(in: context, albumIDs: albumIDs, now: now)
    }

    func screenDidDisappear() {
        screenIsVisible = false
    }

    /// Nothing shows the counts while the screen is hidden, so they wait for its next appearance.
    func libraryDidChange(in context: ModelContext, albumIDs: [UUID], now: Date = Date()) {
        guard screenIsVisible else { return }
        refresh(in: context, albumIDs: albumIDs, now: now)
    }

    /// Recently Added covers the 30 days before `now`, matching the Recently Added collection.
    func refresh(in context: ModelContext, albumIDs: [UUID], now: Date = Date()) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        let all = Self.count(in: context, #Predicate<VaultMedia> { $0.trashedAt == nil })
        let recent = Self.count(in: context, #Predicate<VaultMedia> { $0.trashedAt == nil && $0.importedAt >= cutoff })
        let favorites = Self.count(in: context, #Predicate<VaultMedia> { $0.trashedAt == nil && $0.isFavorite })
        var albums: [UUID: Int] = [:]
        for albumID in albumIDs {
            albums[albumID] = Self.count(
                in: context,
                #Predicate<VaultMedia> { $0.trashedAt == nil && $0.album?.id == albumID }
            )
        }
        if allCount != all { allCount = all }
        if recentCount != recent { recentCount = recent }
        if favoriteCount != favorites { favoriteCount = favorites }
        if albumCounts != albums { albumCounts = albums }
    }

    private static func count(in context: ModelContext, _ predicate: Predicate<VaultMedia>) -> Int {
        (try? context.fetchCount(FetchDescriptor(predicate: predicate))) ?? 0
    }
}
