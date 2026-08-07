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

    private func makeMedia(type: MediaType, bytes: Int64) -> VaultMedia {
        VaultMedia(
            storageIdentifier: UUID().uuidString,
            contentFingerprint: UUID().uuidString,
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
    }
}
