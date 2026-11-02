import Foundation
import Observation

@MainActor
@Observable
final class GalleryViewModel {
    private(set) var items: [VaultMedia] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var query: GalleryQuery
    var selectedIDs: Set<UUID> = []
    var isSelecting = false

    private let repository: VaultRepository
    private let pageSize: Int
    private var loadGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var itemIndexes: [UUID: Int] = [:]

    init(repository: VaultRepository, query: GalleryQuery, pageSize: Int = 80) {
        self.repository = repository
        self.query = query
        self.pageSize = pageSize
    }

    func loadInitial() async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        hasMore = true
        errorMessage = nil
        selectedIDs.removeAll()

        do {
            let page = try repository.fetchMedia(query: query, offset: 0, limit: pageSize)
            guard loadGeneration == generation else { return }
            items = page.items
            hasMore = page.hasMore
        } catch {
            guard loadGeneration == generation else { return }
            items = []
            hasMore = false
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
        if loadGeneration == generation {
            isLoading = false
            hasLoaded = true
        }
    }

    /// Re-fetches as many items as are already loaded, so the grid keeps its scroll depth
    /// while items that left the query drop out and the selection keeps the ones that remain.
    func refreshLoadedItems() async {
        guard hasLoaded else {
            await loadInitial()
            return
        }
        let generation = UUID()
        loadGeneration = generation

        do {
            let page = try repository.fetchMedia(query: query, offset: 0, limit: max(items.count, pageSize))
            guard loadGeneration == generation else { return }
            items = page.items
            hasMore = page.hasMore
            errorMessage = nil
            selectedIDs.formIntersection(page.items.map(\.id))
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
        if loadGeneration == generation { isLoading = false }
    }

    func loadNextIfNeeded(currentItem: VaultMedia) async {
        guard hasMore, !isLoading, currentItem.id == items.last?.id else { return }
        isLoading = true
        do {
            let page = try repository.fetchMedia(query: query, offset: items.count, limit: pageSize)
            items.append(contentsOf: page.items)
            hasMore = page.hasMore
            errorMessage = nil
        } catch {
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
        isLoading = false
    }

    func updateFilter(_ filter: MediaFilter) {
        query.filter = filter
        Task { await loadInitial() }
    }

    func updateSort(_ sort: MediaSortOption) {
        query.sort = sort
        Task { await loadInitial() }
    }

    func updateDateSortDirection(_ direction: MediaDateSortDirection) async {
        query.dateSortDirection = direction
        await loadInitial()
    }

    func updateSearch(_ text: String) {
        query.searchText = text
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await self?.loadInitial()
            } catch {
                return
            }
        }
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        if selectedIDs.isEmpty { isSelecting = false }
    }

    func beginSelection(with id: UUID? = nil) {
        isSelecting = true
        if let id { selectedIDs.insert(id) }
    }

    func endSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    func setFavorite(mediaID: UUID, isFavorite: Bool) {
        do {
            try repository.setFavorite(mediaID: mediaID, isFavorite: isFavorite)
        } catch {
            errorMessage = VaultError.persistenceFailure.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    /// The position of a loaded item, from an index that is rebuilt whenever it no longer matches the items.
    func index(of id: UUID) -> Int? {
        if let index = itemIndexes[id], items.indices.contains(index), items[index].id == id {
            return index
        }
        var indexes: [UUID: Int] = [:]
        indexes.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where indexes[item.id] == nil {
            indexes[item.id] = index
        }
        itemIndexes = indexes
        return indexes[id]
    }
}
