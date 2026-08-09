import Foundation
import SwiftData

struct ReconciliationResult: Sendable, Equatable {
    let repairedLocations: Int
    let deletedOrphans: Int
    let missingFiles: Int
}

@MainActor
final class StorageReconciliationService {
    private let modelContext: ModelContext
    private let storage: any SecureFileStoring
    private let operationGate: VaultOperationGate

    init(
        modelContext: ModelContext,
        storage: any SecureFileStoring,
        operationGate: VaultOperationGate = VaultOperationGate()
    ) {
        self.modelContext = modelContext
        self.storage = storage
        self.operationGate = operationGate
    }

    func reconcile() async throws -> ReconciliationResult {
        try await operationGate.withLock {
            try await self.reconcileExclusively()
        }
    }

    private func reconcileExclusively() async throws -> ReconciliationResult {
        let media = try modelContext.fetch(FetchDescriptor<VaultMedia>())
        let activeReferences = Set(media.filter { !$0.isTrashed }.map(\.storageIdentifier))
        let trashReferences = Set(media.filter(\.isTrashed).map(\.storageIdentifier))
        let thumbnailReferences = Set(media.compactMap(\.thumbnailIdentifier))
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
