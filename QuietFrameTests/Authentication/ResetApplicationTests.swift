import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class ResetApplicationTests: XCTestCase {
    func testAuthenticatedResetRemovesModelsAndCredentials() async throws {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.insert(AppSettings())
        container.mainContext.insert(VaultAlbum(name: "Private"))
        container.mainContext.insert(makeMedia())
        try container.mainContext.save()
        let authentication = MockAuthenticationService()
        let storage = MockSecureFileStorage()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: storage,
            modelContext: container.mainContext
        )
        await coordinator.initializeIfNeeded()
        await coordinator.unlock(passcode: "123456")

        let succeeded = await coordinator.resetApplication(passcode: "123456")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(coordinator.state, .needsOnboarding)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultMedia>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VaultAlbum>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<AppSettings>()), 1)
        let passcodeExists = await authentication.passcodeExists
        let removeAllCount = await storage.removeAllCount
        XCTAssertFalse(passcodeExists)
        XCTAssertEqual(removeAllCount, 1)
    }

    private func makeMedia() -> VaultMedia {
        VaultMedia(
            storageIdentifier: UUID().uuidString,
            contentFingerprint: UUID().uuidString,
            metadata: MediaMetadata(
                mediaType: .photo,
                contentTypeIdentifier: "public.jpeg",
                originalFilename: nil,
                originalCreationDate: nil,
                pixelWidth: 10,
                pixelHeight: 10,
                duration: nil,
                byteCount: 100
            )
        )
    }
}
