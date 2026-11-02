import Foundation
import Observation

@MainActor
@Observable
final class GalleryViewModel {
    private(set) var items: [VaultMedia] = []
    /// The IDs of `items` in the same order, built once per change, so screens can hand them on and find positions
    /// without reading every item's ID.
    private(set) var itemIDs: [UUID] = []
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
    private let positions = MediaPositionIndex()
    /// What every loaded page was fetched under, or nil when the loaded items might differ from a fresh fetch.
    @ObservationIgnored private var loadedSignature: GalleryFetchSignature?

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
        let signature = repository.fetchSignature(for: query)

        do {
            let page = try repository.fetchMedia(query: query, offset: 0, limit: pageSize)
            guard loadGeneration == generation else { return }
            replaceItems(with: page.items)
            hasMore = page.hasMore
            loadedSignature = signature
        } catch {
            guard loadGeneration == generation else { return }
            replaceItems(with: [])
            hasMore = false
            loadedSignature = nil
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
    /// While the fetch signature is unchanged the fetch would return the loaded items, so it is skipped,
    /// and only what changed is written, so an unchanged grid is not invalidated.
    func refreshLoadedItems() async {
        guard hasLoaded else {
            await loadInitial()
            return
        }
        let signature = repository.fetchSignature(for: query)
        if let signature, signature == loadedSignature {
            keepSelectionWithinLoadedItems()
            if errorMessage != nil { errorMessage = nil }
            return
        }
        let generation = UUID()
        loadGeneration = generation

        do {
            let page = try repository.fetchMedia(query: query, offset: 0, limit: max(items.count, pageSize))
            guard loadGeneration == generation else { return }
            if !page.items.elementsEqual(items, by: { $0 === $1 }) {
                replaceItems(with: page.items)
            }
            if hasMore != page.hasMore { hasMore = page.hasMore }
            if errorMessage != nil { errorMessage = nil }
            keepSelectionWithinLoadedItems()
            loadedSignature = signature
        } catch {
            guard loadGeneration == generation else { return }
            loadedSignature = nil
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
        if loadGeneration == generation, isLoading { isLoading = false }
    }

    func loadNextIfNeeded(currentItem: VaultMedia) async {
        guard hasMore, !isLoading, currentItem.id == itemIDs.last else { return }
        isLoading = true
        do {
            let page = try repository.fetchMedia(query: query, offset: items.count, limit: pageSize)
            appendItems(page.items)
            hasMore = page.hasMore
            errorMessage = nil
            if loadedSignature != nil, loadedSignature != repository.fetchSignature(for: query) {
                loadedSignature = nil
            }
        } catch {
            loadedSignature = nil
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

    func setFavorite(mediaIDs: Set<UUID>, isFavorite: Bool) {
        do {
            try repository.setFavorite(mediaIDs: mediaIDs, isFavorite: isFavorite)
        } catch {
            errorMessage = VaultError.persistenceFailure.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    /// The position of a loaded item, without scanning the items on every call.
    func index(of id: UUID) -> Int? {
        positions.index(of: id, in: itemIDs)
    }

    private func replaceItems(with newItems: [VaultMedia]) {
        items = newItems
        itemIDs = newItems.map(\.id)
    }

    private func appendItems(_ newItems: [VaultMedia]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        itemIDs.append(contentsOf: newItems.map(\.id))
    }

    private func keepSelectionWithinLoadedItems() {
        let kept = selectedIDs.filter { index(of: $0) != nil }
        if kept.count != selectedIDs.count { selectedIDs = kept }
    }
}
