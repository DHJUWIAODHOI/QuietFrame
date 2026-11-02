import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

/// Free space is checked for each item before it starts, so an item too large for the device fails on its own.
@MainActor
final class ImportFreeSpaceTests: XCTestCase {
    func testAnItemTooLargeForFreeSpaceFailsAloneAndLaterItemsStillImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capacity = try incoming.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard capacity.volumeAvailableCapacityForImportantUsage != nil else {
            throw XCTSkip("This runner reports no free space for important use, so import skips the check.")
        }
        let container = try makeContainer()
        let session = VaultSession()
        try await session.unlock(with: Data(repeating: 0x4d, count: 32))
        let storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: session, chunkByteCount: 65_536),
            baseURL: root.appendingPathComponent("storage", isDirectory: true),
            temporaryBaseURL: root.appendingPathComponent("cache", isDirectory: true),
            applyFileProtection: false
        )
        let importer = MediaImportService(
            storage: storage,
            repository: VaultRepository(modelContext: container.mainContext)
        )
        let tooLarge = try makeSource(
            at: incoming.appendingPathComponent("huge.mov"),
            mediaType: .video,
            declaredByteCount: Int64(1) << 60
        )
        let photo = try makeSource(at: incoming.appendingPathComponent("photo.jpg"), mediaType: .photo)
        let progress = ProgressLog()

        let summary = try await importer.importMedia(
            [tooLarge, photo],
            albumID: nil,
            preflightFailureCount: 0,
            preflightThumbnailFailureCount: 0
        ) { update in
            await progress.record(update)
        }

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.importedCount, 1)
        let records = try container.mainContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(records.map(\.originalFilename), ["photo.jpg"])
        let updates = await progress.updates
        XCTAssertEqual(updates.first, ImportProgress(completedItems: 1, totalItems: 2, currentItemFraction: 0))
    }

    private func makeSource(
        at url: URL,
        mediaType: MediaType,
        declaredByteCount: Int64? = nil
    ) throws -> ImportSource {
        let bytes = Data(repeating: mediaType == .photo ? 0x31 : 0x72, count: 70_000)
        try bytes.write(to: url)
        return ImportSource(
            temporaryURL: url,
            metadata: MediaMetadata(
                mediaType: mediaType,
                contentTypeIdentifier: mediaType == .photo ? "public.jpeg" : "com.apple.quicktime-movie",
                originalFilename: url.lastPathComponent,
                originalCreationDate: nil,
                pixelWidth: 640,
                pixelHeight: 480,
                duration: mediaType == .video ? 1 : nil,
                byteCount: declaredByteCount ?? Int64(bytes.count)
            ),
            thumbnailJPEGData: nil,
            sourceLocalIdentifier: nil
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private actor ProgressLog {
    private(set) var updates: [ImportProgress] = []

    func record(_ update: ImportProgress) {
        updates.append(update)
    }
}
