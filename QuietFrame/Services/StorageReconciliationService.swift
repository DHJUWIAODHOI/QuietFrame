import Foundation
import SwiftData

struct ReconciliationResult: Sendable, Equatable {
    let repairedLocations: Int
    let deletedOrphans: Int
    let missingFiles: Int
}

@MainActor
final class StorageReconciliationService {
    private struct MediaReferences {
        var active: Set<String> = []
        var trash: Set<String> = []
        var thumbnails: Set<String> = []

        mutating func add(_ media: [VaultMedia]) {
            for item in media {
                if item.isTrashed {
                    trash.insert(item.storageIdentifier)
                } else {
                    active.insert(item.storageIdentifier)
                }
                if let thumbnailIdentifier = item.thumbnailIdentifier {
                    thumbnails.insert(thumbnailIdentifier)
                }
            }
        }
    }

    private let modelContext: ModelContext
    private let storage: any SecureFileStoring
    private let operationGate: VaultOperationGate
    private let pageSize: Int

    init(
        modelContext: ModelContext,
        storage: any SecureFileStoring,
        operationGate: VaultOperationGate = VaultOperationGate(),
        pageSize: Int = 500
    ) {
        self.modelContext = modelContext
        self.storage = storage
        self.operationGate = operationGate
        self.pageSize = max(1, pageSize)
    }

    func reconcile() async throws -> ReconciliationResult {
        try await operationGate.withLock {
            let references = try await mediaReferences()
            let activeReferences = references.active
            let trashReferences = references.trash
            let thumbnailReferences = references.thumbnails
            let allOriginalReferences = activeReferences.union(trashReferences)

            var mediaFiles = try await storage.allIdentifiers(location: .media)
            var trashFiles = try await storage.allIdentifiers(location: .trash)
            let thumbnailFiles = try await storage.allIdentifiers(location: .thumbnails)
            var repaired = 0
            var missing = 0

            for identifier in activeReferences where !mediaFiles.contains(identifier) {
                if trashFiles.contains(identifier) {
                    try await storage.move(identifier: identifier, from: .trash, to: .media)
                    trashFiles.remove(identifier)
                    mediaFiles.insert(identifier)
                    repaired += 1
                } else {
                    missing += 1
                }
            }
            for identifier in trashReferences where !trashFiles.contains(identifier) {
                if mediaFiles.contains(identifier) {
                    try await storage.move(identifier: identifier, from: .media, to: .trash)
                    mediaFiles.remove(identifier)
                    trashFiles.insert(identifier)
                    repaired += 1
                } else {
                    missing += 1
                }
            }

            var deletedOrphans = 0
            for identifier in mediaFiles.subtracting(allOriginalReferences) {
                try await storage.delete(identifier: identifier, location: .media)
                deletedOrphans += 1
            }
            for identifier in trashFiles.subtracting(allOriginalReferences) {
                try await storage.delete(identifier: identifier, location: .trash)
                deletedOrphans += 1
            }
            for identifier in thumbnailFiles.subtracting(thumbnailReferences) {
                try await storage.delete(identifier: identifier, location: .thumbnails)
                deletedOrphans += 1
            }

            return ReconciliationResult(
                repairedLocations: repaired,
                deletedOrphans: deletedOrphans,
                missingFiles: missing
            )
        }
    }

    /// Reads the references a page at a time, yielding the main actor between pages. Locking cancels the maintenance
    /// task, and a cancelled read stops at the next page, before any file is touched. Offset pages partition the stored
    /// rows only while the context has no unsaved changes, so with any the references come from one fetch, as before.
    private func mediaReferences() async throws -> MediaReferences {
        var references = MediaReferences()
        var page = referencesDescriptor()
        page.sortBy = [SortDescriptor(\VaultMedia.id, order: .forward)]
        page.fetchLimit = pageSize
        var offset = 0
        var isLastPage = false
        while !isLastPage {
            try Task.checkCancellation()
            if modelContext.hasChanges {
                let allMedia = try modelContext.fetch(referencesDescriptor())
                var unpaged = MediaReferences()
                unpaged.add(allMedia)
                return unpaged
            }
            page.fetchOffset = offset
            let media = try modelContext.fetch(page)
            references.add(media)
            isLastPage = media.count < pageSize
            if !isLastPage {
                offset += pageSize
                await Task.yield()
            }
        }
        return references
    }

    private func referencesDescriptor() -> FetchDescriptor<VaultMedia> {
        var descriptor = FetchDescriptor<VaultMedia>()
        descriptor.propertiesToFetch = [\.storageIdentifier, \.thumbnailIdentifier, \.trashedAt]
        return descriptor
    }
}
