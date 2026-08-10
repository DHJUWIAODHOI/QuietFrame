import Foundation
import SwiftData

@MainActor
protocol AlbumServicing: AnyObject {
    func createAlbum(name: String) throws -> VaultAlbum
    func renameAlbum(id: UUID, name: String) throws
    func moveMedia(ids: Set<UUID>, toAlbumID: UUID?) throws
    func setCover(albumID: UUID, mediaID: UUID?) throws
    func deleteAlbum(id: UUID, mode: AlbumDeletionMode) async throws
}

@MainActor
final class AlbumService: AlbumServicing {
    private let repository: VaultRepository
    private let modelContext: ModelContext
    private let storage: any SecureFileStoring
    private let operationGate: VaultOperationGate

    init(
        repository: VaultRepository,
        modelContext: ModelContext,
        storage: any SecureFileStoring,
        operationGate: VaultOperationGate = VaultOperationGate()
    ) {
        self.repository = repository
        self.modelContext = modelContext
        self.storage = storage
        self.operationGate = operationGate
    }

    func createAlbum(name: String) throws -> VaultAlbum {
        try repository.createAlbum(name: name)
    }

    func renameAlbum(id: UUID, name: String) throws {
        try repository.renameAlbum(id: id, name: name)
    }

    func moveMedia(ids: Set<UUID>, toAlbumID: UUID?) throws {
        try repository.moveMedia(ids: ids, toAlbumID: toAlbumID)
    }

    func setCover(albumID: UUID, mediaID: UUID?) throws {
        try repository.setAlbumCover(albumID: albumID, mediaID: mediaID)
    }

    func deleteAlbum(id: UUID, mode: AlbumDeletionMode) async throws {
        try await operationGate.withLock {
            var descriptor = FetchDescriptor<VaultAlbum>(predicate: #Predicate { album in album.id == id })
            descriptor.fetchLimit = 1
            guard let album = try modelContext.fetch(descriptor).first else {
                throw VaultError.persistenceFailure
            }
            let activeMedia = album.media.filter { !$0.isTrashed }
            var physicallyMoved: [String] = []

            if mode == .moveMediaToTrash {
                do {
                    for media in activeMedia {
                        try await storage.move(identifier: media.storageIdentifier, from: .media, to: .trash)
                        physicallyMoved.append(media.storageIdentifier)
                    }
                } catch {
                    for identifier in physicallyMoved.reversed() {
                        try? await storage.move(identifier: identifier, from: .trash, to: .media)
                    }
                    throw error
                }
            }

            let deletedAt = Date()
            for media in activeMedia {
                if mode == .moveMediaToTrash {
                    media.previousAlbumID = album.id
                    media.trashedAt = deletedAt
                }
                media.album = nil
                media.modifiedAt = deletedAt
            }
            modelContext.delete(album)

            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                for identifier in physicallyMoved.reversed() {
                    try? await storage.move(identifier: identifier, from: .trash, to: .media)
                }
                throw VaultError.persistenceFailure
            }
        }
    }
}
