import Foundation
import SwiftData

/// Media removed for good, with the thumbnails that leave the memory cache with it.
struct PermanentDeletion: Sendable, Equatable {
    static let nothing = PermanentDeletion(deletedCount: 0, thumbnailIdentifiers: [])

    let deletedCount: Int
    let thumbnailIdentifiers: [String]
}

@MainActor
protocol TrashServicing: AnyObject {
    func moveToTrash(ids: Set<UUID>) async throws
    func restore(ids: Set<UUID>) async throws
    func permanentlyDelete(ids: Set<UUID>) async throws
    func emptyTrash() async throws -> PermanentDeletion
    func purgeExpiredItems() async throws -> PermanentDeletion
}

@MainActor
final class TrashService: TrashServicing {
    private let modelContext: ModelContext
    private let storage: any SecureFileStoring
    private let operationGate: VaultOperationGate
    private let changes: LibraryChangeCounter

    init(
        modelContext: ModelContext,
        storage: any SecureFileStoring,
        operationGate: VaultOperationGate = VaultOperationGate(),
        changes: LibraryChangeCounter = LibraryChangeCounter()
    ) {
        self.modelContext = modelContext
        self.storage = storage
        self.operationGate = operationGate
        self.changes = changes
    }

    func moveToTrash(ids: Set<UUID>) async throws {
        try await operationGate.withLock {
            let media = try fetchMedia(ids: ids).filter { !$0.isTrashed }
            guard media.count == ids.count else { throw VaultError.persistenceFailure }

            let batch = await storage.move(identifiers: media.map(\.storageIdentifier), from: .media, to: .trash)
            if let failure = batch.failure {
                await restorePhysicalFiles(batch.moved)
                throw failure
            }
            let moved = batch.moved

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
            changes.recordChange()
        }
    }

    func restore(ids: Set<UUID>) async throws {
        try await operationGate.withLock {
            let media = try fetchMedia(ids: ids).filter(\.isTrashed)
            guard media.count == ids.count else { throw VaultError.persistenceFailure }

            let batch = await storage.move(identifiers: media.map(\.storageIdentifier), from: .trash, to: .media)
            if let failure = batch.failure {
                await movePhysicalFilesBackToTrash(batch.moved)
                throw failure
            }
            let moved = batch.moved

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
            changes.recordChange()
        }
    }

    func permanentlyDelete(ids: Set<UUID>) async throws {
        _ = try await operationGate.withLock {
            try await self.permanentlyDeleteExclusively(ids: ids)
        }
    }

    private func permanentlyDeleteExclusively(ids: Set<UUID>) async throws -> PermanentDeletion {
        let media = try fetchMedia(ids: ids).filter(\.isTrashed)
        guard media.count == ids.count else { throw VaultError.persistenceFailure }

        let filesPerItem = media.map { item -> [EncryptedFileReference] in
            var files = [EncryptedFileReference(identifier: item.storageIdentifier, location: .trash)]
            if let thumbnailIdentifier = item.thumbnailIdentifier {
                files.append(EncryptedFileReference(identifier: thumbnailIdentifier, location: .thumbnails))
            }
            return files
        }
        let deletion = PermanentDeletion(
            deletedCount: media.count,
            thumbnailIdentifiers: media.compactMap(\.thumbnailIdentifier)
        )
        media.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw VaultError.persistenceFailure
        }
        changes.recordChange()

        let failedItemCount = await storage.deleteFiles(ofItems: filesPerItem)
        if failedItemCount > 0 {
            // Metadata is already gone, so inaccessible encrypted orphans are removed by reconciliation.
            throw VaultError.fileOperationFailed
        }
        return deletion
    }

    func emptyTrash() async throws -> PermanentDeletion {
        try await operationGate.withLock {
            let descriptor = FetchDescriptor<VaultMedia>(
                predicate: #Predicate { media in media.trashedAt != nil }
            )
            let ids = Set(try modelContext.fetch(descriptor).map(\.id))
            guard !ids.isEmpty else { return PermanentDeletion.nothing }
            return try await permanentlyDeleteExclusively(ids: ids)
        }
    }

    func purgeExpiredItems() async throws -> PermanentDeletion {
        try await operationGate.withLock {
            var settingsDescriptor = FetchDescriptor<AppSettings>()
            settingsDescriptor.fetchLimit = 1
            let retentionDays = try modelContext.fetch(settingsDescriptor).first?.trashRetentionDays ?? 30
            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
            let descriptor = FetchDescriptor<VaultMedia>(
                predicate: #Predicate { media in media.trashedAt != nil }
            )
            let expiredIDs = Set<UUID>(try modelContext.fetch(descriptor).compactMap { media in
                guard let trashedAt = media.trashedAt, trashedAt <= cutoff else { return nil }
                return media.id
            })
            guard !expiredIDs.isEmpty else { return PermanentDeletion.nothing }
            return try await permanentlyDeleteExclusively(ids: expiredIDs)
        }
    }

    private func fetchMedia(ids: Set<UUID>) throws -> [VaultMedia] {
        guard !ids.isEmpty else { return [] }
        return try modelContext.fetchMedia(ids: ids)
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
