import Foundation
import SwiftData
import XCTest
@testable import QuietFrame

@MainActor
final class VaultLockCoordinatorTests: XCTestCase {
    func testImmediateBackgroundLockRemovesUnlockedState() async throws {
        let container = try makeContainer(autoLock: .immediately)
        let authentication = MockAuthenticationService()
        let storage = MockSecureFileStorage()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: storage,
            modelContext: container.mainContext
        )

        await coordinator.initializeIfNeeded()
        await coordinator.unlock(passcode: "123456")
        XCTAssertEqual(coordinator.state, .unlocked)

        await coordinator.handleLifecycle(.background)

        XCTAssertEqual(coordinator.state, .locked)
        let lockCount = await authentication.lockCount
        XCTAssertEqual(lockCount, 1)
    }

    func testElapsedGracePeriodLocksWhenAppReturns() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        let storage = MockSecureFileStorage()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_000))
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: storage,
            modelContext: container.mainContext,
            now: clock.now
        )

        await coordinator.initializeIfNeeded()
        await coordinator.unlock(passcode: "123456")
        await coordinator.handleLifecycle(.background)
        clock.advance(by: 61)
        await coordinator.handleLifecycle(.active)

        XCTAssertEqual(coordinator.state, .locked)
    }

    func testNoPasscodeModeSilentlyReopensAfterBackgroundLock() async throws {
        let container = try makeContainer(autoLock: .immediately)
        let authentication = MockAuthenticationService()
        try await authentication.removePasscode(current: "123456")
        let storage = MockSecureFileStorage()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: storage,
            modelContext: container.mainContext
        )

        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.authenticationMode, .none)
        XCTAssertEqual(coordinator.state, .unlocked)

        await coordinator.handleLifecycle(.background)
        XCTAssertEqual(coordinator.state, .locked)

        await coordinator.handleLifecycle(.active)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testNoPasscodeForegroundDoesNotRevokeActiveEncryption() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.bin")
        let encryptedURL = directory.appendingPathComponent("encrypted.qfe")
        try Data(repeating: 0x6c, count: 200_000).write(to: sourceURL)

        let session = VaultSession()
        let authentication = MockAuthenticationService(session: session)
        try await authentication.removePasscode(current: "123456")
        let maintenance = TestAsyncCounter()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { await maintenance.increment() }
        )

        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.state, .unlocked)

        let encryption = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        _ = try await encryption.encryptFile(at: sourceURL, to: encryptedURL) { fraction in
            guard fraction > 0 else { return }
            await coordinator.handleLifecycle(.inactive)
            await coordinator.handleLifecycle(.active)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
        let unlockCount = await authentication.unlockWithoutPasscodeCount
        let maintenanceCount = await maintenance.value
        XCTAssertEqual(unlockCount, 1)
        XCTAssertEqual(maintenanceCount, 1)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    private func makeContainer(autoLock: AutoLockPeriod) throws -> ModelContainer {
        let schema = Schema([
            VaultMedia.self,
            VaultAlbum.self,
            AppSettings.self,
            ImportRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.insert(AppSettings(autoLockPeriod: autoLock))
        try container.mainContext.save()
        return container
    }
}

private actor TestAsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        let value = date
        lock.unlock()
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}
