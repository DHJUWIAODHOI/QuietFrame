import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class MediaImportServiceTests: XCTestCase {
    func testImportPersistsEncryptedMediaAndDetectsDuplicateContent() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageRoot = testRoot.appendingPathComponent("storage", isDirectory: true)
        let cacheRoot = testRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let modelContainer = try makeModelContainer()
        let repository = VaultRepository(modelContext: modelContainer.mainContext)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x4d, count: 32))
        let encryption = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        let storage = try SecureFileStorageService(
            encryption: encryption,
            baseURL: storageRoot,
            temporaryBaseURL: cacheRoot,
            applyFileProtection: false
        )
        let importer = MediaImportService(storage: storage, repository: repository)

        let bytes = Data((0..<80_000).map { UInt8($0 % 223) })
        let firstURL = cacheRoot.appendingPathComponent("first.jpg")
        let secondURL = cacheRoot.appendingPathComponent("second.jpg")
        try bytes.write(to: firstURL)
        try bytes.write(to: secondURL)
        let metadata = MediaMetadata(
            mediaType: .photo,
            contentTypeIdentifier: "public.jpeg",
            originalFilename: "sample.jpg",
            originalCreationDate: Date(timeIntervalSince1970: 500),
            pixelWidth: 640,
            pixelHeight: 480,
            duration: nil,
            byteCount: Int64(bytes.count)
        )

        let firstSummary = try await importer.importMedia(
            [ImportSource(
                temporaryURL: firstURL,
                metadata: metadata,
                thumbnailJPEGData: nil,
                sourceLocalIdentifier: "asset-1"
            )],
            albumID: nil,
            preflightFailureCount: 1,
            preflightThumbnailFailureCount: 1,
            progress: nil
        )
        let duplicateSummary = try await importer.importMedia(
            [ImportSource(
                temporaryURL: secondURL,
                metadata: metadata,
                thumbnailJPEGData: nil,
                sourceLocalIdentifier: nil
            )],
            albumID: nil,
            preflightFailureCount: 0,
            preflightThumbnailFailureCount: 0,
            progress: nil
        )

        XCTAssertEqual(firstSummary.importedCount, 1)
        XCTAssertEqual(firstSummary.failedCount, 1)
        XCTAssertEqual(firstSummary.thumbnailFailureCount, 1)
        XCTAssertEqual(firstSummary.importedSourceLocalIdentifiers, ["asset-1"])
        XCTAssertTrue(firstSummary.shouldOfferOriginalDeletion)
        XCTAssertEqual(duplicateSummary.duplicateCount, 1)
        let importRecords = try modelContainer.mainContext.fetch(FetchDescriptor<ImportRecord>())
        XCTAssertTrue(importRecords.contains {
            $0.requestedCount == 2 && $0.importedCount == 1 && $0.failedCount == 1
        })
        let records = try modelContainer.mainContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.originalFilename, "sample.jpg")
        XCTAssertEqual(records.first?.pixelWidth, 640)
    }

    func testImportAssignsEveryPhotoAndVideoToSelectedAlbum() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let album = try environment.repository.createAlbum(name: "Selected")
        let sources = try [
            makeSource(
                at: environment.cache.appendingPathComponent("photo.jpg"),
                bytes: Data(repeating: 0x31, count: 70_000),
                mediaType: .photo,
                filename: "photo.jpg"
            ),
            makeSource(
                at: environment.cache.appendingPathComponent("video.mov"),
                bytes: Data(repeating: 0x72, count: 90_000),
                mediaType: .video,
                filename: "video.mov"
            )
        ]

        let summary = try await environment.importer.importMedia(
            sources,
            albumID: album.id,
            preflightFailureCount: 0,
            preflightThumbnailFailureCount: 0,
            progress: nil
        )

        let records = try environment.container.mainContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.album?.id == album.id })
        XCTAssertEqual(records.map(\.mediaTypeRawValue).sorted(), ["photo", "video"])
    }

    func testEachItemCanGoToItsOwnAlbumWithTheRestUsingTheDefault() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let family = try environment.repository.createAlbum(name: "Family")
        let documents = try environment.repository.createAlbum(name: "Documents")
        let defaultAlbum = try environment.repository.createAlbum(name: "Inbox")
        var familyPhoto = try makeSource(
            at: environment.cache.appendingPathComponent("family.jpg"),
            bytes: Data(repeating: 0x11, count: 70_000),
            mediaType: .photo,
            filename: "family.jpg"
        )
        familyPhoto.albumID = family.id
        var passport = try makeSource(
            at: environment.cache.appendingPathComponent("passport.jpg"),
            bytes: Data(repeating: 0x22, count: 70_000),
            mediaType: .photo,
            filename: "passport.jpg"
        )
        passport.albumID = documents.id
        let unassignedVideo = try makeSource(
            at: environment.cache.appendingPathComponent("clip.mov"),
            bytes: Data(repeating: 0x33, count: 90_000),
            mediaType: .video,
            filename: "clip.mov"
        )

        let summary = try await environment.importer.importMedia(
            [familyPhoto, passport, unassignedVideo],
            albumID: defaultAlbum.id,
            preflightFailureCount: 0,
            preflightThumbnailFailureCount: 0,
            progress: nil
        )

        XCTAssertEqual(summary.importedCount, 3)
        let records = try environment.container.mainContext.fetch(FetchDescriptor<VaultMedia>())
        let albumsByFilename = Dictionary(
            uniqueKeysWithValues: records.map { ($0.originalFilename ?? "", $0.album?.name) }
        )
        XCTAssertEqual(albumsByFilename["family.jpg"], "Family")
        XCTAssertEqual(albumsByFilename["passport.jpg"], "Documents")
        XCTAssertEqual(albumsByFilename["clip.mov"], "Inbox")
    }

    func testImportWithNoAlbumKeepsMediaUnassigned() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try makeSource(
            at: environment.cache.appendingPathComponent("unassigned.jpg"),
            bytes: Data(repeating: 0x43, count: 70_000),
            mediaType: .photo,
            filename: "unassigned.jpg"
        )

        let summary = try await environment.importer.importMedia(
            [source],
            albumID: nil,
            preflightFailureCount: 0,
            preflightThumbnailFailureCount: 0,
            progress: nil
        )

        let records = try environment.container.mainContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.album)
    }

    func testStaleAlbumIDRemovesEncryptedMediaAndThumbnail() async throws {
        let environment = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let staleAlbumID = UUID()
        let source = try makeSource(
            at: environment.cache.appendingPathComponent("stale.jpg"),
            bytes: Data(repeating: 0x54, count: 70_000),
            mediaType: .photo,
            filename: "stale.jpg",
            thumbnailData: Data(repeating: 0x65, count: 2_048)
        )

        XCTAssertThrowsError(try environment.repository.insertImportedMedia(
            storageIdentifier: "missing",
            thumbnailIdentifier: "missing-thumbnail",
            fingerprint: UUID().uuidString,
            metadata: source.metadata,
            albumID: staleAlbumID
        )) { error in
            XCTAssertEqual(error as? VaultError, .persistenceFailure)
        }

        let summary = try await environment.importer.importMedia(
            [source],
            albumID: staleAlbumID,
            preflightFailureCount: 0,
            preflightThumbnailFailureCount: 0,
            progress: nil
        )

        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(try environment.container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 0)
        let mediaIdentifiers = try await environment.storage.allIdentifiers(location: .media)
        let thumbnailIdentifiers = try await environment.storage.allIdentifiers(location: .thumbnails)
        XCTAssertTrue(mediaIdentifiers.isEmpty)
        XCTAssertTrue(thumbnailIdentifiers.isEmpty)
    }

    private func makeEnvironment() async throws -> (
        root: URL,
        cache: URL,
        container: ModelContainer,
        repository: VaultRepository,
        storage: SecureFileStorageService,
        importer: MediaImportService
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let container = try makeModelContainer()
        let repository = VaultRepository(modelContext: container.mainContext)
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x4d, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session, chunkByteCount: 65_536),
            baseURL: storageRoot,
            temporaryBaseURL: cache,
            applyFileProtection: false
        )
        return (root, cache, container, repository, storage, MediaImportService(storage: storage, repository: repository))
    }

    private func makeSource(
        at url: URL,
        bytes: Data,
        mediaType: MediaType,
        filename: String,
        thumbnailData: Data? = nil
    ) throws -> ImportSource {
        try bytes.write(to: url)
        return ImportSource(
            temporaryURL: url,
            metadata: MediaMetadata(
                mediaType: mediaType,
                contentTypeIdentifier: mediaType == .photo ? "public.jpeg" : "com.apple.quicktime-movie",
                originalFilename: filename,
                originalCreationDate: nil,
                pixelWidth: 640,
                pixelHeight: 480,
                duration: mediaType == .video ? 1 : nil,
                byteCount: Int64(bytes.count)
            ),
            thumbnailJPEGData: thumbnailData,
            sourceLocalIdentifier: nil
        )
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            VaultMedia.self,
            VaultAlbum.self,
            AppSettings.self,
            ImportRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
