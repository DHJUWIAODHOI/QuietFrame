import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class StorageAnalysisServiceTests: XCTestCase {
    func testSummarySeparatesPhotosVideosAndTrash() async throws {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let photo = makeMedia(type: .photo, bytes: 2_000)
        let video = makeMedia(type: .video, bytes: 8_000)
        let trashed = makeMedia(type: .photo, bytes: 3_000)
        trashed.trashedAt = Date()
        container.mainContext.insert(photo)
        container.mainContext.insert(video)
        container.mainContext.insert(trashed)
        container.mainContext.insert(VaultAlbum(name: "One"))
        try container.mainContext.save()
        let service = StorageAnalysisService(
            modelContext: container.mainContext,
            storage: MockSecureFileStorage()
        )

        let summary = try await service.analyze()

        XCTAssertEqual(summary.photoBytes, 1_024)
        XCTAssertEqual(summary.videoBytes, 1_024)
        XCTAssertEqual(summary.trashBytes, 1_024)
        XCTAssertEqual(summary.mediaCount, 3)
        XCTAssertEqual(summary.albumCount, 1)
        XCTAssertEqual(summary.largestItems.first?.id, video.id)
    }

    func testAnalysisListsEachLocationOnceOnRealFiles() async throws {
        let container = try makeContainer()
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let photo = try vault.place(in: .media, byteCount: 1_000)
        let photoThumbnail = try vault.place(in: .thumbnails, byteCount: 100)
        let video = try vault.place(in: .media, byteCount: 5_000)
        let videoThumbnail = try vault.place(in: .thumbnails, byteCount: 200)
        let photoWithoutThumbnail = try vault.place(in: .media, byteCount: 2_000)
        let trashedPhoto = try vault.place(in: .trash, byteCount: 3_000)
        let trashedPhotoThumbnail = try vault.place(in: .thumbnails, byteCount: 300)
        let trashedVideo = try vault.place(in: .trash, byteCount: 7_000)
        let sharedThumbnail = try vault.place(in: .thumbnails, byteCount: 50)
        let firstSharing = try vault.place(in: .media, byteCount: 400)
        let secondSharing = try vault.place(in: .media, byteCount: 600)
        try vault.place(in: .media, byteCount: 11)
        let context = container.mainContext
        context.insert(makeMedia(type: .photo, bytes: 6_000, file: photo, thumbnail: photoThumbnail))
        context.insert(makeMedia(type: .video, bytes: 50_000, file: video, thumbnail: videoThumbnail))
        context.insert(makeMedia(type: .photo, bytes: 2_500, file: photoWithoutThumbnail))
        context.insert(makeMedia(
            type: .photo,
            bytes: 90_000,
            file: trashedPhoto,
            thumbnail: trashedPhotoThumbnail,
            trashed: true
        ))
        context.insert(makeMedia(type: .video, bytes: 70_000, file: trashedVideo, trashed: true))
        context.insert(makeMedia(type: .photo, bytes: 4_000, file: firstSharing, thumbnail: sharedThumbnail))
        context.insert(makeMedia(type: .photo, bytes: 3_000, file: secondSharing, thumbnail: sharedThumbnail))
        context.insert(VaultAlbum(name: "One"))
        try context.save()
        let counting = CountingSecureFileStorage(wrapping: vault.storage)
        let service = StorageAnalysisService(modelContext: ModelContext(container), storage: counting)

        let summary = try await service.analyze()

        let oracleContext = ModelContext(container)
        let expected = try await PerFileStorageAnalysis.summary(context: oracleContext, storage: vault.storage)
        XCTAssertEqual(summary, expected)
        XCTAssertEqual(summary.photoBytes, 4_000)
        XCTAssertEqual(summary.videoBytes, 5_000)
        XCTAssertEqual(summary.trashBytes, 10_000)
        XCTAssertEqual(summary.thumbnailBytes, 700)
        XCTAssertEqual(summary.totalEncryptedBytes, 19_700)
        XCTAssertEqual(summary.mediaCount, 7)
        XCTAssertEqual(summary.albumCount, 1)
        XCTAssertEqual(summary.largestItems.map(\.byteCount), [50_000, 6_000, 4_000, 3_000, 2_500])
        let fileByteCountCalls = await counting.fileByteCountCalls
        let fileByteCountsCalls = await counting.fileByteCountsCalls
        XCTAssertEqual(fileByteCountCalls, 0)
        XCTAssertEqual(fileByteCountsCalls, 3)
    }

    func testAnalysisMatchesThePerFileOracleInEdgeCases() async throws {
        try await assertAnalysisMatchesOracle("Uppercase identifier, lowercase file") { vault, context in
            let identifier = try vault.place(in: .media, byteCount: 321)
            context.insert(self.makeMedia(type: .photo, bytes: 10, file: identifier.uppercased()))
        }
        try await assertAnalysisMatchesOracle("Identifier that is not a UUID") { vault, context in
            try vault.place("not-a-uuid", in: .media, byteCount: 12)
            context.insert(self.makeMedia(type: .photo, bytes: 10, file: "not-a-uuid"))
        }
        try await assertAnalysisMatchesOracle("Missing original") { vault, context in
            let present = try vault.place(in: .media, byteCount: 40)
            context.insert(self.makeMedia(type: .photo, bytes: 10, file: present))
            context.insert(self.makeMedia(type: .video, bytes: 20, file: UUID().uuidString.lowercased()))
        }
        try await assertAnalysisMatchesOracle("Missing thumbnail") { vault, context in
            let original = try vault.place(in: .trash, byteCount: 40)
            let missingThumbnail = UUID().uuidString.lowercased()
            context.insert(self.makeMedia(
                type: .photo,
                bytes: 10,
                file: original,
                thumbnail: missingThumbnail,
                trashed: true
            ))
        }
        try await assertAnalysisMatchesOracle("Directory with a vault file's name") { vault, context in
            let identifier = UUID().uuidString.lowercased()
            try FileManager.default.createDirectory(
                at: vault.url(of: identifier, in: .media),
                withIntermediateDirectories: false
            )
            context.insert(self.makeMedia(type: .photo, bytes: 10, file: identifier))
        }
        try await assertAnalysisMatchesOracle("Location that cannot be listed") { vault, context in
            let identifier = try vault.place(in: .media, byteCount: 40)
            context.insert(self.makeMedia(type: .photo, bytes: 10, file: identifier))
            try FileManager.default.removeItem(at: vault.directory(for: .media))
        }
        try await assertAnalysisMatchesOracle("Files that belong to no item") { vault, context in
            let original = try vault.place(in: .media, byteCount: 70)
            let thumbnail = try vault.place(in: .thumbnails, byteCount: 7)
            let trashed = try vault.place(in: .trash, byteCount: 700)
            context.insert(self.makeMedia(type: .photo, bytes: 10, file: original, thumbnail: thumbnail))
            context.insert(self.makeMedia(type: .video, bytes: 20, file: trashed, trashed: true))
            for location in [EncryptedAssetLocation.media, .trash, .thumbnails] {
                try vault.place(in: location, byteCount: 5_000)
                try vault.place(".\(UUID().uuidString.lowercased())", in: location, byteCount: 5_000)
                try vault.place("not-a-uuid", in: location, byteCount: 5_000)
                let textFile = vault.directory(for: location)
                    .appendingPathComponent("\(UUID().uuidString.lowercased()).txt")
                try Data(repeating: 0x42, count: 5_000).write(to: textFile)
            }
        }
    }

    func testLargestFilesKeepFetchOrderAmongEqualSizes() async throws {
        let container = try makeContainer()
        for index in 0..<30 {
            container.mainContext.insert(makeMedia(
                type: index % 4 == 0 ? .video : .photo,
                bytes: Int64(1_000 * (index % 3 + 1))
            ))
        }
        for _ in 0..<5 {
            container.mainContext.insert(makeMedia(type: .photo, bytes: 9_000, trashed: true))
        }
        try container.mainContext.save()
        let service = StorageAnalysisService(modelContext: ModelContext(container), storage: MockSecureFileStorage())

        let summary = try await service.analyze()

        let legacyContext = ModelContext(container)
        let legacy = try legacyContext.fetch(FetchDescriptor<VaultMedia>())
            .filter { !$0.isTrashed }
            .sorted { $0.byteCount > $1.byteCount }
            .prefix(20)
        XCTAssertEqual(summary.largestItems.map(\.id), legacy.map(\.id))
        XCTAssertEqual(summary.largestItems.map(\.name), legacy.map(\.displayName))
        XCTAssertEqual(summary.largestItems.map(\.mediaType), legacy.map(\.mediaType))
        XCTAssertEqual(Set(summary.largestItems.map(\.byteCount)), [3_000, 2_000])
    }

    func testEmptyLibraryMakesNoStorageCalls() async throws {
        let container = try makeContainer()
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        let counting = CountingSecureFileStorage(wrapping: vault.storage)
        let service = StorageAnalysisService(modelContext: container.mainContext, storage: counting)

        let summary = try await service.analyze()

        let expected = try await PerFileStorageAnalysis.summary(context: container.mainContext, storage: vault.storage)
        XCTAssertEqual(summary, expected)
        XCTAssertEqual(summary.totalEncryptedBytes, 0)
        XCTAssertTrue(summary.largestItems.isEmpty)
        let totalCalls = await counting.totalCalls
        XCTAssertEqual(totalCalls, 0)
    }

    /// Both analyses see the same store and files, and must agree on the summary or on the error.
    private func assertAnalysisMatchesOracle(
        _ scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        arrange: (TemporaryVaultStorage, ModelContext) throws -> Void
    ) async throws {
        let container = try makeContainer()
        let vault = try TemporaryVaultStorage()
        defer { vault.remove() }
        try arrange(vault, container.mainContext)
        try container.mainContext.save()
        let service = StorageAnalysisService(modelContext: container.mainContext, storage: vault.storage)

        let analyzed = await outcome { try await service.analyze() }
        let oracle = await outcome {
            try await PerFileStorageAnalysis.summary(context: container.mainContext, storage: vault.storage)
        }

        XCTAssertEqual(analyzed, oracle, scenario, file: file, line: line)
    }

    private func outcome(of analysis: () async throws -> StorageSummary) async -> AnalysisOutcome {
        do {
            let summary = try await analysis()
            return .summary(summary)
        } catch let error as VaultError {
            return .vaultError(error)
        } catch {
            let nsError = error as NSError
            return .otherError(domain: nsError.domain, code: nsError.code)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeMedia(
        type: MediaType,
        bytes: Int64,
        file storageIdentifier: String = UUID().uuidString,
        thumbnail thumbnailIdentifier: String? = nil,
        trashed: Bool = false
    ) -> VaultMedia {
        let media = VaultMedia(
            storageIdentifier: storageIdentifier,
            contentFingerprint: UUID().uuidString,
            thumbnailIdentifier: thumbnailIdentifier,
            metadata: MediaMetadata(
                mediaType: type,
                contentTypeIdentifier: type == .photo ? "public.jpeg" : "public.mpeg-4",
                originalFilename: nil,
                originalCreationDate: nil,
                pixelWidth: 10,
                pixelHeight: 10,
                duration: type == .video ? 2 : nil,
                byteCount: bytes
            )
        )
        if trashed {
            media.trashedAt = Date()
        }
        return media
    }
}

private enum AnalysisOutcome: Equatable {
    case summary(StorageSummary)
    case vaultError(VaultError)
    case otherError(domain: String, code: Int)
}
