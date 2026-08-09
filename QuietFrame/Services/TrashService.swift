import Foundation
import SwiftData

@MainActor
protocol TrashServicing: AnyObject {
    func moveToTrash(ids: Set<UUID>) async throws
    func restore(ids: Set<UUID>) async throws
    func permanentlyDelete(ids: Set<UUID>) async throws
    func emptyTrash() async throws
    func purgeExpiredItems() async throws -> Int
}

@MainActor
final class TrashService: TrashServicing {
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

    func moveToTrash(ids: Set<UUID>) async throws {
        try await operationGate.withLock {
            try await self.moveToTrashExclusively(ids: ids)
        }
    }

    private func moveToTrashExclusively(ids: Set<UUID>) async throws {
        let media = try fetchMedia(ids: ids).filter { !$0.isTrashed }
        guard media.count == ids.count else { throw VaultError.persistenceFailure }
        var moved: [String] = []

        do {
            for item in media {
                try await storage.move(identifier: item.storageIdentifier, from: .media, to: .trash)
                moved.append(item.storageIdentifier)
            }
        } catch {
            await restorePhysicalFiles(moved)
            throw error
        }

        let deletionDate = Date()
        for item in media {
            if item.album?.coverMediaID == item.id {
                item.album?.coverMediaID = nil
            }
            item.album?.modifiedAt = deletionDate
            item.previousAlbumID = item.album?.id
            item.album = nil
            item.trashedAt = deletionDate
            item.modifiedAt = deletionDate
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            await restorePhysicalFiles(moved)
            throw VaultError.persistenceFailure
        }
    }

    func restore(ids: Set<UUID>) async throws {
        try await operationGate.withLock {
            try await self.restoreExclusively(ids: ids)
        }
    }

    private func restoreExclusively(ids: Set<UUID>) async throws {
        let media = try fetchMedia(ids: ids).filter(\.isTrashed)
        guard media.count == ids.count else { throw VaultError.persistenceFailure }
        var moved: [String] = []

        do {
            for item in media {
                try await storage.move(identifier: item.storageIdentifier, from: .trash, to: .media)
                moved.append(item.storageIdentifier)
            }
        } catch {
            await movePhysicalFilesBackToTrash(moved)
            throw error
        }

        let albums = try modelContext.fetch(FetchDescriptor<VaultAlbum>())
        let restoredAt = Date()
        for item in media {
            item.album = item.previousAlbumID.flatMap { previousID in
                albums.first(where: { $0.id == previousID })
            }
            item.album?.modifiedAt = restoredAt
            item.previousAlbumID = nil
            item.trashedAt = nil
            item.modifiedAt = restoredAt
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            await movePhysicalFilesBackToTrash(moved)
            throw VaultError.persistenceFailure
        }
    }

    func permanentlyDelete(ids: Set<UUID>) async throws {
        try await operationGate.withLock {
            try await self.permanentlyDeleteExclusively(ids: ids)
        }
    }

    private func permanentlyDeleteExclusively(ids: Set<UUID>) async throws {
        let media = try fetchMedia(ids: ids).filter(\.isTrashed)
        guard media.count == ids.count else { throw VaultError.persistenceFailure }

        let fileReferences = media.map {
            (storageIdentifier: $0.storageIdentifier, thumbnailIdentifier: $0.thumbnailIdentifier)
        }
        media.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw VaultError.persistenceFailure
        }

        var deletionFailed = false
        for reference in fileReferences {
            do {
                try await storage.delete(identifier: reference.storageIdentifier, location: .trash)
                if let thumbnailIdentifier = reference.thumbnailIdentifier {
                    try await storage.delete(identifier: thumbnailIdentifier, location: .thumbnails)
                }
            } catch {
                deletionFailed = true
            }
        }
        if deletionFailed {
            // Metadata is already gone, so inaccessible encrypted orphans are removed by reconciliation.
            throw VaultError.fileOperationFailed
        }
    }

    func emptyTrash() async throws {
        try await operationGate.withLock {
            try await self.emptyTrashExclusively()
        }
    }

    private func emptyTrashExclusively() async throws {
        let descriptor = FetchDescriptor<VaultMedia>(
            predicate: #Predicate { media in media.trashedAt != nil }
        )
        let ids = Set(try modelContext.fetch(descriptor).map(\.id))
        guard !ids.isEmpty else { return }
        try await permanentlyDeleteExclusively(ids: ids)
    }

    func purgeExpiredItems() async throws -> Int {
        try await operationGate.withLock {
            try await self.purgeExpiredItemsExclusively()
        }
    }

    private func purgeExpiredItemsExclusively() async throws -> Int {
        var settingsDescriptor = FetchDescriptor<AppSettings>()
        settingsDescriptor.fetchLimit = 1
        let retentionDays = try modelContext.fetch(settingsDescriptor).first?.trashRetentionDays ?? 30
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        let descriptor = FetchDescriptor<VaultMedia>(
            predicate: #Predicate { media in media.trashedAt != nil }
        )
        let expiredIDValues: [UUID] = try modelContext.fetch(descriptor).compactMap { media in
            guard let trashedAt = media.trashedAt, trashedAt <= cutoff else { return nil }
            return media.id
        }
        let expiredIDs = Set<UUID>(expiredIDValues)
        guard !expiredIDs.isEmpty else { return 0 }
        try await permanentlyDeleteExclusively(ids: expiredIDs)
        return expiredIDs.count
    }

    private func fetchMedia(ids: Set<UUID>) throws -> [VaultMedia] {
        guard !ids.isEmpty else { return [] }
        return try modelContext.fetch(FetchDescriptor<VaultMedia>()).filter { ids.contains($0.id) }
    }

    private func restorePhysicalFiles(_ identifiers: [String]) async {
        for identifier in identifiers.reversed() {
            try? await storage.move(identifier: identifier, from: .trash, to: .media)
        }
    }

    private func movePhysicalFilesBackToTrash(_ identifiers: [String]) async {
        for identifier in identifiers.reversed() {
            try? await storage.move(identifier: identifier, from: .media, to: .trash)
        }
    }
}
