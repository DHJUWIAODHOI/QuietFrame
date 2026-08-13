import Foundation
import SwiftData

@MainActor
protocol VaultRepositoryProtocol: AnyObject {
    func containsFingerprint(_ fingerprint: String) throws -> Bool
    func insertImportedMedia(
        storageIdentifier: String,
        thumbnailIdentifier: String?,
        fingerprint: String,
        metadata: MediaMetadata,
        albumID: UUID?
    ) throws -> UUID
    func deleteImportedMedia(id: UUID) throws
    func beginImport(requestedCount: Int) throws -> UUID
    func finishImport(id: UUID, summary: ImportSummary, status: ImportStatus) throws
    func fetchMedia(query: GalleryQuery, offset: Int, limit: Int) throws -> (items: [VaultMedia], hasMore: Bool)
    func createAlbum(name: String) throws -> VaultAlbum
    func renameAlbum(id: UUID, name: String) throws
    func moveMedia(ids: Set<UUID>, toAlbumID: UUID?) throws
    func setAlbumCover(albumID: UUID, mediaID: UUID?) throws
    func setFavorite(mediaID: UUID, isFavorite: Bool) throws
}

@MainActor
final class VaultRepository: VaultRepositoryProtocol {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func containsFingerprint(_ fingerprint: String) throws -> Bool {
        var descriptor = FetchDescriptor<VaultMedia>(
            predicate: #Predicate { media in
                media.contentFingerprint == fingerprint
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func insertImportedMedia(
        storageIdentifier: String,
        thumbnailIdentifier: String?,
        fingerprint: String,
        metadata: MediaMetadata,
        albumID: UUID?
    ) throws -> UUID {
        let album = try albumID.map { id in
            guard let album = try findAlbum(id: id) else {
                throw VaultError.persistenceFailure
            }
            return album
        }
        let importedAt = Date()
        let media = VaultMedia(
            storageIdentifier: storageIdentifier,
            contentFingerprint: fingerprint,
            thumbnailIdentifier: thumbnailIdentifier,
            metadata: metadata,
            importedAt: importedAt,
            album: album
        )
        album?.modifiedAt = importedAt
        modelContext.insert(media)
        do {
            try modelContext.save()
            return media.id
        } catch {
            modelContext.delete(media)
            throw VaultError.persistenceFailure
        }
    }

    func beginImport(requestedCount: Int) throws -> UUID {
        let record = ImportRecord(requestedCount: requestedCount)
        modelContext.insert(record)
        do {
            try modelContext.save()
            return record.id
        } catch {
            modelContext.delete(record)
            throw VaultError.persistenceFailure
        }
    }

    func deleteImportedMedia(id: UUID) throws {
        var descriptor = FetchDescriptor<VaultMedia>(
            predicate: #Predicate { media in media.id == id }
        )
        descriptor.fetchLimit = 1
        guard let media = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(media)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw VaultError.persistenceFailure
        }
    }

    func finishImport(id: UUID, summary: ImportSummary, status: ImportStatus) throws {
        var descriptor = FetchDescriptor<ImportRecord>(
            predicate: #Predicate { record in
                record.id == id
            }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            throw VaultError.persistenceFailure
        }
        record.importedCount = summary.importedCount
        record.duplicateCount = summary.duplicateCount
        record.failedCount = summary.failedCount
        record.finishedAt = Date()
        record.status = status
        do {
            try modelContext.save()
        } catch {
            throw VaultError.persistenceFailure
        }
    }

    func fetchMedia(
        query: GalleryQuery,
        offset: Int,
        limit: Int
    ) throws -> (items: [VaultMedia], hasMore: Bool) {
        guard offset >= 0, limit > 0 else {
            throw VaultError.invalidInput("The gallery page is invalid.")
        }
        var descriptor = baseMediaDescriptor(for: query)
        descriptor.sortBy = sortDescriptors(for: query.sort, dateDirection: query.dateSortDirection)

        let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty {
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit + 1
            let fetched = try modelContext.fetch(descriptor)
            return (Array(fetched.prefix(limit)), fetched.count > limit)
        }

        let allMatchingScope = try modelContext.fetch(descriptor)
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let searched = allMatchingScope.filter { media in
            media.originalFilename?.localizedCaseInsensitiveContains(search) == true
                || media.album?.name.localizedCaseInsensitiveContains(search) == true
                || media.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
                || dateFormatter.string(from: media.importedAt).localizedCaseInsensitiveContains(search)
                || media.originalCreationDate.map {
                    dateFormatter.string(from: $0).localizedCaseInsensitiveContains(search)
                } == true
                || Int(calendar.component(.year, from: media.importedAt)).description == search
        }
        guard offset < searched.count else { return ([], false) }
        let end = min(offset + limit, searched.count)
        return (Array(searched[offset..<end]), end < searched.count)
    }

    func createAlbum(name: String) throws -> VaultAlbum {
        let validatedName = try validateAlbumName(name)
        guard try !albumNameExists(validatedName, excluding: nil) else {
            throw VaultError.invalidInput("An album with this name already exists.")
        }
        let highestPosition = try modelContext.fetch(FetchDescriptor<VaultAlbum>()).map(\.position).max() ?? -1
        let album = VaultAlbum(name: validatedName, position: highestPosition + 1)
        modelContext.insert(album)
        do {
            try modelContext.save()
            return album
        } catch {
            modelContext.delete(album)
            throw VaultError.persistenceFailure
        }
    }

    func renameAlbum(id: UUID, name: String) throws {
        let validatedName = try validateAlbumName(name)
        guard try !albumNameExists(validatedName, excluding: id),
              let album = try findAlbum(id: id) else {
            throw VaultError.invalidInput("This album name is unavailable.")
        }
        album.name = validatedName
        album.modifiedAt = Date()
        try saveChanges()
    }

    func reorderAlbums(ids: [UUID]) throws {
        let albums = try modelContext.fetch(FetchDescriptor<VaultAlbum>())
        let albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        guard ids.count == albums.count,
              Set(ids) == Set(albumsByID.keys) else {
            throw VaultError.invalidInput("The album order is invalid.")
        }
        guard !albums.isEmpty else { return }
        var settingsDescriptor = FetchDescriptor<AppSettings>()
        settingsDescriptor.fetchLimit = 1
        guard let settings = try modelContext.fetch(settingsDescriptor).first else {
            throw VaultError.persistenceFailure
        }
        settings.albumSort = .manual
        for (position, id) in ids.enumerated() {
            albumsByID[id]?.position = position
        }
        try saveChanges()
    }

    func moveMedia(ids: Set<UUID>, toAlbumID: UUID?) throws {
        guard !ids.isEmpty else { return }
        let destination = try toAlbumID.flatMap { try findAlbum(id: $0) }
        let descriptor = FetchDescriptor<VaultMedia>()
        let matching = try modelContext.fetch(descriptor).filter { ids.contains($0.id) && !$0.isTrashed }
        guard matching.count == ids.count else { throw VaultError.persistenceFailure }
        var sourceAlbums: [UUID: VaultAlbum] = [:]
        for item in matching {
            if let album = item.album { sourceAlbums[album.id] = album }
        }
        matching.forEach {
            $0.album = destination
            $0.modifiedAt = Date()
        }
        for sourceAlbum in sourceAlbums.values {
            sourceAlbum.modifiedAt = Date()
            if let coverMediaID = sourceAlbum.coverMediaID, ids.contains(coverMediaID) {
                sourceAlbum.coverMediaID = nil
            }
        }
        destination?.modifiedAt = Date()
        try saveChanges()
    }

    func setAlbumCover(albumID: UUID, mediaID: UUID?) throws {
        guard let album = try findAlbum(id: albumID) else { throw VaultError.persistenceFailure }
        if let mediaID {
            guard album.media.contains(where: { $0.id == mediaID && !$0.isTrashed }) else {
                throw VaultError.invalidInput("Choose an item from this album as its cover.")
            }
        }
        album.coverMediaID = mediaID
        album.modifiedAt = Date()
        try saveChanges()
    }

    func setFavorite(mediaID: UUID, isFavorite: Bool) throws {
        var descriptor = FetchDescriptor<VaultMedia>(
            predicate: #Predicate { media in media.id == mediaID }
        )
        descriptor.fetchLimit = 1
        guard let media = try modelContext.fetch(descriptor).first else {
            throw VaultError.persistenceFailure
        }
        media.isFavorite = isFavorite
        media.modifiedAt = Date()
        media.album?.modifiedAt = Date()
        try saveChanges()
    }

    private func findAlbum(id: UUID) throws -> VaultAlbum? {
        var descriptor = FetchDescriptor<VaultAlbum>(
            predicate: #Predicate { album in
                album.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func baseMediaDescriptor(for query: GalleryQuery) -> FetchDescriptor<VaultMedia> {
        if query.includesTrash {
            switch query.filter {
            case .photos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt != nil && media.mediaTypeRawValue == "photo"
                })
            case .videos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt != nil && media.mediaTypeRawValue == "video"
                })
            case .favorites:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt != nil && media.isFavorite
                })
            case .all:
                return FetchDescriptor(predicate: #Predicate { media in media.trashedAt != nil })
            }
        }

        if let albumID = query.albumID {
            switch query.filter {
            case .photos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.album?.id == albumID && media.mediaTypeRawValue == "photo"
                })
            case .videos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.album?.id == albumID && media.mediaTypeRawValue == "video"
                })
            case .favorites:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.album?.id == albumID && media.isFavorite
                })
            case .all:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.album?.id == albumID
                })
            }
        }

        if query.collection == .recentlyAdded {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            switch query.filter {
            case .photos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.importedAt >= cutoff && media.mediaTypeRawValue == "photo"
                })
            case .videos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.importedAt >= cutoff && media.mediaTypeRawValue == "video"
                })
            case .favorites:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.importedAt >= cutoff && media.isFavorite
                })
            case .all:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.importedAt >= cutoff
                })
            }
        }
        if query.collection == .favorites {
            switch query.filter {
            case .photos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.isFavorite && media.mediaTypeRawValue == "photo"
                })
            case .videos:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.isFavorite && media.mediaTypeRawValue == "video"
                })
            case .all, .favorites:
                return FetchDescriptor(predicate: #Predicate { media in
                    media.trashedAt == nil && media.isFavorite
                })
            }
        }
        if query.filter == .favorites {
            return FetchDescriptor(predicate: #Predicate { media in media.trashedAt == nil && media.isFavorite })
        }
        switch query.filter {
        case .photos:
            return FetchDescriptor(predicate: #Predicate { media in
                media.trashedAt == nil && media.mediaTypeRawValue == "photo"
            })
        case .videos:
            return FetchDescriptor(predicate: #Predicate { media in
                media.trashedAt == nil && media.mediaTypeRawValue == "video"
            })
        case .all, .favorites:
            return FetchDescriptor(predicate: #Predicate { media in media.trashedAt == nil })
        }
    }

    private func sortDescriptors(
        for option: MediaSortOption,
        dateDirection: MediaDateSortDirection
    ) -> [SortDescriptor<VaultMedia>] {
        let dateOrder: SortOrder = dateDirection == .newestFirst ? .reverse : .forward
        switch option {
        case .importedAt:
            return [SortDescriptor(\VaultMedia.importedAt, order: dateOrder),
                    SortDescriptor(\VaultMedia.storageIdentifier, order: .forward)]
        case .createdAt:
            return [SortDescriptor(\VaultMedia.originalCreationDate, order: dateOrder),
                    SortDescriptor(\VaultMedia.importedAt, order: dateOrder),
                    SortDescriptor(\VaultMedia.storageIdentifier, order: .forward)]
        case .name:
            return [SortDescriptor(\VaultMedia.originalFilename, order: .forward),
                    SortDescriptor(\VaultMedia.storageIdentifier, order: .forward)]
        case .size:
            return [SortDescriptor(\VaultMedia.byteCount, order: .reverse),
                    SortDescriptor(\VaultMedia.storageIdentifier, order: .forward)]
        case .type:
            return [SortDescriptor(\VaultMedia.mediaTypeRawValue, order: .forward),
                    SortDescriptor(\VaultMedia.importedAt, order: .reverse),
                    SortDescriptor(\VaultMedia.storageIdentifier, order: .forward)]
        }
    }

    private func validateAlbumName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            throw VaultError.invalidInput("Album names must contain 1 to 80 characters.")
        }
        return trimmed
    }

    private func albumNameExists(_ name: String, excluding id: UUID?) throws -> Bool {
        try modelContext.fetch(FetchDescriptor<VaultAlbum>()).contains { album in
            album.id != id && album.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func saveChanges() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw VaultError.persistenceFailure
        }
    }
}
