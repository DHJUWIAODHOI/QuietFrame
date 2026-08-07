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
                sourceLocalIdentifier: nil
            )],
            albumID: nil,
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
            progress: nil
        )

        XCTAssertEqual(firstSummary.importedCount, 1)
        XCTAssertEqual(duplicateSummary.duplicateCount, 1)
        let records = try modelContainer.mainContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.originalFilename, "sample.jpg")
        XCTAssertEqual(records.first?.pixelWidth, 640)
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
