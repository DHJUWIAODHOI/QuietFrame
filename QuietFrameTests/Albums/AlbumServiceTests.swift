import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class AlbumServiceTests: XCTestCase {
    func testCreateAndRenameAlbum() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)

        let album = try repository.createAlbum(name: "  Family  ")
        XCTAssertEqual(album.name, "Family")

        try repository.renameAlbum(id: album.id, name: "Journeys")
        XCTAssertEqual(album.name, "Journeys")
    }

    func testDeletingAlbumKeepsMediaByDefault() async throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let storage = MockSecureFileStorage()
        let service = AlbumService(
            repository: repository,
            modelContext: container.mainContext,
            storage: storage
        )
        let album = try repository.createAlbum(name: "Private")
        let media = makeMedia(album: album)
        container.mainContext.insert(media)
        try container.mainContext.save()

        try await service.deleteAlbum(id: album.id, mode: .keepMedia)

        XCTAssertNil(media.album)
        XCTAssertNil(media.trashedAt)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultAlbum>()), 0)
        let moveCount = await storage.moveCount
        XCTAssertEqual(moveCount, 0)
    }

    func testExplicitDeleteToTrashMovesEncryptedFile() async throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let storage = MockSecureFileStorage()
        let service = AlbumService(
            repository: repository,
            modelContext: container.mainContext,
            storage: storage
        )
        let album = try repository.createAlbum(name: "Receipts")
        let albumID = album.id
        let media = makeMedia(album: album)
        container.mainContext.insert(media)
        try container.mainContext.save()

        try await service.deleteAlbum(id: albumID, mode: .moveMediaToTrash)

        XCTAssertNotNil(media.trashedAt)
        XCTAssertEqual(media.previousAlbumID, albumID)
        let moveCount = await storage.moveCount
        XCTAssertEqual(moveCount, 1)
    }

    func testFailedDeleteToTrashKeepsTheAlbumAndItsFiles() async throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let service = AlbumService(
            repository: repository,
            modelContext: container.mainContext,
            storage: vault.storage
        )
        let album = try repository.createAlbum(name: "Receipts")
        let albumID = album.id
        var media: [VaultMedia] = []
        for _ in 0..<3 {
            let identifier = try vault.place(in: .media)
            let item = makeMedia(album: album, storageIdentifier: identifier)
            container.mainContext.insert(item)
            media.append(item)
        }
        try container.mainContext.save()
        let blocked = media[1].storageIdentifier
        try vault.place(blocked, in: .trash)

        do {
            try await service.deleteAlbum(id: albumID, mode: .moveMediaToTrash)
            XCTFail("The move into a taken name should fail.")
        } catch {
            XCTAssertEqual(error as? VaultError, .fileOperationFailed)
        }

        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultAlbum>()), 1)
        for item in media {
            XCTAssertEqual(item.album?.id, albumID)
            XCTAssertNil(item.trashedAt)
            XCTAssertNil(item.previousAlbumID)
            XCTAssertTrue(vault.contains(item.storageIdentifier, in: .media))
        }
        XCTAssertEqual(try vault.fileNames(in: .trash), ["\(blocked).qfe"])
    }

    func testInitialOrderingAndCreationAfterReorder() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let first = try repository.createAlbum(name: "First")
        let second = try repository.createAlbum(name: "Second")
        let third = try repository.createAlbum(name: "Third")

        XCTAssertEqual([first.position, second.position, third.position], [0, 1, 2])

        try repository.reorderAlbums(ids: [third.id, first.id, second.id])
        let fourth = try repository.createAlbum(name: "Fourth")

        XCTAssertEqual(fourth.position, 3)
        XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [third.id, first.id, second.id, fourth.id])
    }

    func testMultipleReordersAndTemporarySortsPreserveManualOrder() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let first = try repository.createAlbum(name: "Zebra")
        let second = try repository.createAlbum(name: "Alpha")
        let third = try repository.createAlbum(name: "Middle")

        try repository.reorderAlbums(ids: [third.id, first.id, second.id])
        try repository.reorderAlbums(ids: [second.id, third.id, first.id])

        let settings = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(settings.albumSort, .manual)
        let savedPositions = try albumPositions(in: container.mainContext)

        settings.albumSort = .name
        try container.mainContext.save()
        settings.albumSort = .creationDate
        try container.mainContext.save()
        settings.albumSort = .manual
        try container.mainContext.save()

        XCTAssertEqual(try albumPositions(in: container.mainContext), savedPositions)
        XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [second.id, third.id, first.id])
    }

    func testInvalidAndDuplicateAlbumIDsDoNotChangeOrder() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let first = try repository.createAlbum(name: "First")
        let second = try repository.createAlbum(name: "Second")
        let originalPositions = try albumPositions(in: container.mainContext)

        XCTAssertThrowsError(try repository.reorderAlbums(ids: [first.id, first.id]))
        XCTAssertThrowsError(try repository.reorderAlbums(ids: [first.id]))
        XCTAssertThrowsError(try repository.reorderAlbums(ids: [first.id, UUID()]))

        XCTAssertEqual(try albumPositions(in: container.mainContext), originalPositions)
        XCTAssertEqual(try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<AppSettings>()).first).albumSort, .modifiedDate)
        XCTAssertEqual(Set(originalPositions.keys), [first.id, second.id])
    }

    func testEmptyAndSingleAlbumReorders() throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)

        XCTAssertNoThrow(try repository.reorderAlbums(ids: []))
        let album = try repository.createAlbum(name: "Only")
        XCTAssertNoThrow(try repository.reorderAlbums(ids: [album.id]))

        XCTAssertEqual(album.position, 0)
        XCTAssertEqual(try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<AppSettings>()).first).albumSort, .manual)
    }

    func testReorderPersistsAfterStoreReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Vault.store")

        let expectedIDs = try autoreleasepool { () throws -> [UUID] in
            let container = try makeLatestContainer(at: storeURL)
            container.mainContext.insert(AppSettings())
            try container.mainContext.save()
            let repository = VaultRepository(modelContext: container.mainContext)
            let first = try repository.createAlbum(name: "First")
            let second = try repository.createAlbum(name: "Second")
            let third = try repository.createAlbum(name: "Third")
            let ids = [third.id, first.id, second.id]
            try repository.reorderAlbums(ids: ids)
            return ids
        }

        try autoreleasepool {
            let container = try makeLatestContainer(at: storeURL)
            XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), expectedIDs)
            let settings = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<AppSettings>()).first)
            XCTAssertEqual(settings.albumSort, .manual)
        }
    }

    func testDeletingAlbumsFromDifferentPositionsLeavesRemainingOrderIntact() async throws {
        let container = try makeContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let service = AlbumService(
            repository: repository,
            modelContext: container.mainContext,
            storage: MockSecureFileStorage()
        )
        let first = try repository.createAlbum(name: "First")
        let second = try repository.createAlbum(name: "Second")
        let third = try repository.createAlbum(name: "Third")
        let fourth = try repository.createAlbum(name: "Fourth")
        try repository.reorderAlbums(ids: [fourth.id, second.id, first.id, third.id])

        try await service.deleteAlbum(id: fourth.id, mode: .keepMedia)
        XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [second.id, first.id, third.id])
        XCTAssertEqual(try albumPositions(in: container.mainContext).values.sorted(), [1, 2, 3])

        try await service.deleteAlbum(id: first.id, mode: .keepMedia)
        XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [second.id, third.id])
        XCTAssertEqual(try albumPositions(in: container.mainContext).values.sorted(), [1, 3])

        try await service.deleteAlbum(id: third.id, mode: .keepMedia)
        XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [second.id])
        XCTAssertEqual(second.position, 1)

        let appended = try repository.createAlbum(name: "Appended")
        XCTAssertEqual(appended.position, 2)
        XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [second.id, appended.id])
    }

    func testMigratesDiskBackedV1StoreWithoutChangingPersistedData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Vault.store")
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let thirdID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let mediaID = UUID()
        let firstCreatedAt = Date(timeIntervalSince1970: 100)
        let tiedCreatedAt = Date(timeIntervalSince1970: 200)
        let firstModifiedAt = Date(timeIntervalSince1970: 900)
        let mediaImportedAt = Date(timeIntervalSince1970: 300)
        let mediaCreatedAt = Date(timeIntervalSince1970: 50)
        let mediaModifiedAt = Date(timeIntervalSince1970: 350)
        let mediaTrashedAt = Date(timeIntervalSince1970: 600)
        let settingsCreatedAt = Date(timeIntervalSince1970: 700)
        let settingsModifiedAt = Date(timeIntervalSince1970: 750)
        let importID = UUID()
        let importStartedAt = Date(timeIntervalSince1970: 400)
        let importFinishedAt = Date(timeIntervalSince1970: 500)

        try autoreleasepool {
            let schema = Schema(versionedSchema: VaultSchemaV1.self)
            let configuration = ModelConfiguration("MigrationTest", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let first = VaultSchemaV1.VaultAlbum(id: firstID, name: "First", createdAt: firstCreatedAt)
            let second = VaultSchemaV1.VaultAlbum(id: secondID, name: "Second", createdAt: tiedCreatedAt)
            let third = VaultSchemaV1.VaultAlbum(id: thirdID, name: "Third", createdAt: tiedCreatedAt)
            first.modifiedAt = firstModifiedAt
            let media = VaultSchemaV1.VaultMedia(
                id: mediaID,
                storageIdentifier: "stored-media",
                contentFingerprint: "fingerprint",
                thumbnailIdentifier: "thumbnail",
                mediaTypeRawValue: "photo",
                contentTypeIdentifier: "public.jpeg",
                originalFilename: "original.jpg",
                importedAt: mediaImportedAt,
                originalCreationDate: mediaCreatedAt,
                pixelWidth: 640,
                pixelHeight: 480,
                duration: 3.5,
                byteCount: 1_024,
                isFavorite: true,
                tags: ["private"],
                trashedAt: mediaTrashedAt,
                previousAlbumID: secondID
            )
            media.modifiedAt = mediaModifiedAt
            let settings = VaultSchemaV1.AppSettings(
                singletonKey: "primary",
                biometricsEnabled: true,
                autoLockSeconds: 60,
                trashRetentionDays: 15,
                appearanceRawValue: "dark",
                thumbnailSizeRawValue: "large",
                albumSortRawValue: "name",
                createdAt: settingsCreatedAt
            )
            settings.modifiedAt = settingsModifiedAt
            let importRecord = VaultSchemaV1.ImportRecord(
                id: importID,
                requestedCount: 2,
                startedAt: importStartedAt
            )
            importRecord.finishedAt = importFinishedAt
            importRecord.importedCount = 1
            importRecord.duplicateCount = 1
            importRecord.failedCount = 1
            importRecord.statusRawValue = "completed"
            container.mainContext.insert(first)
            container.mainContext.insert(second)
            container.mainContext.insert(third)
            container.mainContext.insert(media)
            media.album = first
            first.coverMediaID = mediaID
            container.mainContext.insert(settings)
            container.mainContext.insert(importRecord)
            try container.mainContext.save()
        }

        try autoreleasepool {
            let container = try makeLatestContainer(at: storeURL, configurationName: "MigrationTest")
            let migratedBeforeBackfill = try container.mainContext.fetch(FetchDescriptor<VaultAlbum>())
            XCTAssertEqual(Set(migratedBeforeBackfill.map(\.position)), Set([0]))

            try AppModel.initializeAlbumPositions(in: container.mainContext)
            XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [firstID, secondID, thirdID])
            let positions = try albumPositions(in: container.mainContext)
            try AppModel.initializeAlbumPositions(in: container.mainContext)
            XCTAssertEqual(try albumPositions(in: container.mainContext), positions)

            let albums = try container.mainContext.fetch(FetchDescriptor<VaultAlbum>())
            let first = try XCTUnwrap(albums.first(where: { $0.id == firstID }))
            XCTAssertEqual(first.name, "First")
            XCTAssertEqual(first.createdAt, firstCreatedAt)
            XCTAssertEqual(first.modifiedAt, firstModifiedAt)
            XCTAssertEqual(first.coverMediaID, mediaID)
            XCTAssertEqual(first.media.map(\.id), [mediaID])
            let media = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<VaultMedia>()).first)
            XCTAssertEqual(media.id, mediaID)
            XCTAssertEqual(media.album?.id, firstID)
            XCTAssertEqual(media.storageIdentifier, "stored-media")
            XCTAssertEqual(media.contentFingerprint, "fingerprint")
            XCTAssertEqual(media.thumbnailIdentifier, "thumbnail")
            XCTAssertEqual(media.mediaTypeRawValue, "photo")
            XCTAssertEqual(media.contentTypeIdentifier, "public.jpeg")
            XCTAssertEqual(media.originalFilename, "original.jpg")
            XCTAssertEqual(media.importedAt, mediaImportedAt)
            XCTAssertEqual(media.originalCreationDate, mediaCreatedAt)
            XCTAssertEqual(media.modifiedAt, mediaModifiedAt)
            XCTAssertEqual(media.pixelWidth, 640)
            XCTAssertEqual(media.pixelHeight, 480)
            XCTAssertEqual(media.duration, 3.5)
            XCTAssertEqual(media.byteCount, 1_024)
            XCTAssertEqual(media.tags, ["private"])
            XCTAssertTrue(media.isFavorite)
            XCTAssertEqual(media.trashedAt, mediaTrashedAt)
            XCTAssertEqual(media.previousAlbumID, secondID)
            let settings = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<AppSettings>()).first)
            XCTAssertEqual(settings.singletonKey, "primary")
            XCTAssertTrue(settings.biometricsEnabled)
            XCTAssertEqual(settings.autoLockSeconds, 60)
            XCTAssertEqual(settings.trashRetentionDays, 15)
            XCTAssertEqual(settings.appearanceRawValue, "dark")
            XCTAssertEqual(settings.thumbnailSizeRawValue, "large")
            XCTAssertEqual(settings.albumSort, .name)
            XCTAssertEqual(settings.albumMediaDateSortDirection, .newestFirst)
            XCTAssertEqual(settings.createdAt, settingsCreatedAt)
            XCTAssertEqual(settings.modifiedAt, settingsModifiedAt)
            let importRecord = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ImportRecord>()).first)
            XCTAssertEqual(importRecord.id, importID)
            XCTAssertEqual(importRecord.startedAt, importStartedAt)
            XCTAssertEqual(importRecord.finishedAt, importFinishedAt)
            XCTAssertEqual(importRecord.requestedCount, 2)
            XCTAssertEqual(importRecord.importedCount, 1)
            XCTAssertEqual(importRecord.duplicateCount, 1)
            XCTAssertEqual(importRecord.failedCount, 1)
            XCTAssertEqual(importRecord.status, .completed)
        }

        try autoreleasepool {
            let container = try makeLatestContainer(at: storeURL, configurationName: "MigrationTest")
            XCTAssertEqual(try orderedAlbumIDs(in: container.mainContext), [firstID, secondID, thirdID])
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<AppSettings>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ImportRecord>()), 1)
        }
    }

    func testMigratesDiskBackedV2StoreToV3WithNewestFirstDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Vault.store")
        let albumID = UUID()
        let mediaID = UUID()
        let importID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let importedAt = Date(timeIntervalSince1970: 200)

        try autoreleasepool {
            let schema = Schema(versionedSchema: VaultSchemaV2.self)
            let configuration = ModelConfiguration("V2MigrationTest", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let album = VaultSchemaV2.VaultAlbum(
                id: albumID,
                name: "Existing Album",
                createdAt: createdAt,
                position: 7,
                coverMediaID: mediaID
            )
            container.mainContext.insert(album)
            try container.mainContext.save()
            let media = VaultSchemaV2.VaultMedia(
                id: mediaID,
                storageIdentifier: "existing-storage",
                contentFingerprint: "existing-fingerprint",
                originalFilename: "existing.jpg",
                importedAt: importedAt,
                originalCreationDate: createdAt,
                byteCount: 1_024,
                isFavorite: true,
                tags: ["existing"],
                album: album
            )
            let settings = VaultSchemaV2.AppSettings(
                biometricsEnabled: true,
                autoLockSeconds: 60,
                trashRetentionDays: 15,
                appearanceRawValue: "dark",
                thumbnailSizeRawValue: "large",
                albumSortRawValue: "manual",
                createdAt: createdAt
            )
            let importRecord = VaultSchemaV2.ImportRecord(
                id: importID,
                requestedCount: 1,
                startedAt: importedAt
            )
            importRecord.importedCount = 1
            importRecord.statusRawValue = "completed"
            container.mainContext.insert(media)
            container.mainContext.insert(settings)
            container.mainContext.insert(importRecord)
            try container.mainContext.save()
        }

        try autoreleasepool {
            let container = try makeLatestContainer(at: storeURL, configurationName: "V2MigrationTest")
            let album = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<VaultAlbum>()).first)
            let media = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<VaultMedia>()).first)
            let settings = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<AppSettings>()).first)
            let importRecord = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ImportRecord>()).first)

            XCTAssertEqual(album.id, albumID)
            XCTAssertEqual(album.name, "Existing Album")
            XCTAssertEqual(album.position, 7)
            XCTAssertEqual(album.coverMediaID, mediaID)
            XCTAssertEqual(album.media.map(\.id), [mediaID])
            XCTAssertEqual(media.id, mediaID)
            XCTAssertEqual(media.storageIdentifier, "existing-storage")
            XCTAssertEqual(media.contentFingerprint, "existing-fingerprint")
            XCTAssertEqual(media.album?.id, albumID)
            XCTAssertEqual(media.importedAt, importedAt)
            XCTAssertEqual(media.originalCreationDate, createdAt)
            XCTAssertEqual(media.tags, ["existing"])
            XCTAssertTrue(media.isFavorite)
            XCTAssertTrue(settings.biometricsEnabled)
            XCTAssertEqual(settings.autoLockSeconds, 60)
            XCTAssertEqual(settings.trashRetentionDays, 15)
            XCTAssertEqual(settings.appearanceRawValue, "dark")
            XCTAssertEqual(settings.thumbnailSizeRawValue, "large")
            XCTAssertEqual(settings.albumSort, .manual)
            XCTAssertEqual(settings.albumMediaDateSortDirection, .newestFirst)
            XCTAssertEqual(importRecord.id, importID)
            XCTAssertEqual(importRecord.importedCount, 1)
            XCTAssertEqual(importRecord.status, .completed)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            VaultMedia.self,
            VaultAlbum.self,
            AppSettings.self,
            ImportRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.insert(AppSettings())
        try container.mainContext.save()
        return container
    }

    private func makeLatestContainer(
        at storeURL: URL,
        configurationName: String = "OrderingTest"
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: VaultSchemaV3.self)
        let configuration = ModelConfiguration(configurationName, schema: schema, url: storeURL)
        return try ModelContainer(
            for: schema,
            migrationPlan: VaultMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private func orderedAlbumIDs(in context: ModelContext) throws -> [UUID] {
        try context.fetch(FetchDescriptor<VaultAlbum>())
            .sorted { $0.position < $1.position }
            .map(\.id)
    }

    private func albumPositions(in context: ModelContext) throws -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<VaultAlbum>()).map {
            ($0.id, $0.position)
        })
    }

    private func makeMedia(album: VaultAlbum, storageIdentifier: String = UUID().uuidString) -> VaultMedia {
        VaultMedia(
            storageIdentifier: storageIdentifier,
            contentFingerprint: UUID().uuidString,
            metadata: MediaMetadata(
                mediaType: .photo,
                contentTypeIdentifier: "public.jpeg",
                originalFilename: "sample.jpg",
                originalCreationDate: nil,
                pixelWidth: 100,
                pixelHeight: 100,
                duration: nil,
                byteCount: 1_024
            ),
            album: album
        )
    }
}
