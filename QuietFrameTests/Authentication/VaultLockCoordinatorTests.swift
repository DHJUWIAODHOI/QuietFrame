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
        let authentication = AuthenticationService(
            keychain: MockKeychainService(),
            session: session
        )
        try await authentication.createWithoutPasscode()
        let maintenance = TestAsyncCounter()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { try await maintenance.increment() },
            maintenanceDelay: 0
        )

        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.state, .unlocked)
        await coordinator.waitForMaintenance()

        let encryption = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        _ = try await encryption.encryptFile(at: sourceURL, to: encryptedURL) { fraction in
            guard fraction > 0 else { return }
            await coordinator.handleLifecycle(.inactive)
            await coordinator.handleLifecycle(.active)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
        let maintenanceCount = await maintenance.value
        XCTAssertEqual(maintenanceCount, 1)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testMaintenanceFailureLeavesTheVaultOpenAndRunsAgainAtTheNextUnlock() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        try await authentication.removePasscode(current: "123456")
        let maintenance = TestAsyncCounter(nextError: .fileOperationFailed)
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { try await maintenance.increment() },
            maintenanceDelay: 0
        )

        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.state, .unlocked)
        await coordinator.waitForMaintenance()
        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertNil(coordinator.userMessage)

        await coordinator.lock()
        await coordinator.resumeWithoutPasscodeIfNeeded()
        await coordinator.waitForMaintenance()

        let maintenanceCount = await maintenance.value
        XCTAssertEqual(maintenanceCount, 2)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testPasscodeUnlockRunsTheStorageCheckOnceAfterOpening() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let maintenance = TestAsyncCounter()
        let coordinator = VaultLockCoordinator(
            authentication: MockAuthenticationService(),
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { try await maintenance.increment() },
            maintenanceDelay: 0
        )
        await coordinator.initializeIfNeeded()

        await coordinator.unlock(passcode: "123456")
        await coordinator.waitForMaintenance()

        let maintenanceCount = await maintenance.value
        XCTAssertEqual(maintenanceCount, 1)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testBiometricUnlockRunsTheStorageCheckOnceAfterOpening() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let maintenance = TestAsyncCounter()
        let coordinator = VaultLockCoordinator(
            authentication: MockAuthenticationService(),
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { try await maintenance.increment() },
            maintenanceDelay: 0
        )
        await coordinator.initializeIfNeeded()

        await coordinator.unlockWithBiometrics()
        await coordinator.waitForMaintenance()

        let maintenanceCount = await maintenance.value
        XCTAssertEqual(maintenanceCount, 1)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testCreatingAPasscodeRunsTheStorageCheckOnceAndOpensWhenItFails() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        try await authentication.resetCredentials()
        let maintenance = TestAsyncCounter(nextError: .fileOperationFailed)
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { try await maintenance.increment() },
            maintenanceDelay: 0
        )
        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.state, .needsOnboarding)

        await coordinator.createPasscode("123456", confirmation: "123456")
        await coordinator.waitForMaintenance()

        let maintenanceCount = await maintenance.value
        XCTAssertEqual(maintenanceCount, 1)
        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertNil(coordinator.userMessage)
    }

    func testCreatingWithoutAPasscodeRunsTheStorageCheckOnceAndOpensWhenItFails() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        try await authentication.resetCredentials()
        let maintenance = TestAsyncCounter(nextError: .fileOperationFailed)
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { try await maintenance.increment() },
            maintenanceDelay: 0
        )
        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.state, .needsOnboarding)

        await coordinator.createWithoutPasscode()
        await coordinator.waitForMaintenance()

        let maintenanceCount = await maintenance.value
        XCTAssertEqual(maintenanceCount, 1)
        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertNil(coordinator.userMessage)
    }

    func testPasscodeUnlockOpensBeforeTheStorageCheckRuns() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        let maintenance = TestAsyncCounter()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext,
            postUnlockMaintenance: { try await maintenance.increment() },
            maintenanceDelay: 60
        )
        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.state, .locked)

        await coordinator.unlock(passcode: "123456")

        XCTAssertEqual(coordinator.state, .unlocked)
        let countRightAfterUnlock = await maintenance.value
        XCTAssertEqual(countRightAfterUnlock, 0)
        await coordinator.lock()
        await coordinator.waitForMaintenance()
        let countAfterLocking = await maintenance.value
        XCTAssertEqual(countAfterLocking, 0, "A check still waiting when the vault locks is skipped")
    }

    func testKeychainFailureCanRetryWithoutRecovery() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        await authentication.setNextError(.keychainFailure)
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext
        )

        await coordinator.initializeIfNeeded()
        XCTAssertEqual(coordinator.state, .retryRequired)

        await authentication.setNextError(nil)
        await coordinator.retryOpeningVault()
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testResetAuthenticationFailurePreservesUnlockedVault() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        let storage = MockSecureFileStorage()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: storage,
            modelContext: container.mainContext
        )
        await coordinator.initializeIfNeeded()
        await coordinator.unlock(passcode: "123456")
        await authentication.setNextError(.invalidPasscode)

        let succeeded = await coordinator.resetApplication(passcode: "000000")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(coordinator.state, .unlocked)
        let removeAllCount = await storage.removeAllCount
        XCTAssertEqual(removeAllCount, 0)
    }

    func testCancelledDeviceAuthenticationPreservesHealthyNoPasscodeVault() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        let authentication = MockAuthenticationService()
        try await authentication.removePasscode(current: "123456")
        let storage = MockSecureFileStorage()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: storage,
            modelContext: container.mainContext
        )
        await coordinator.initializeIfNeeded()
        await authentication.setNextError(.authenticationFailed)

        let succeeded = await coordinator.resetUnrecoverableApplication()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(coordinator.state, .unlocked)
        let removeAllCount = await storage.removeAllCount
        XCTAssertEqual(removeAllCount, 0)
    }

    func testPersistedMediaWithoutCredentialsRequiresRecovery() async throws {
        let container = try makeContainer(autoLock: .oneMinute)
        container.mainContext.insert(makeMedia())
        try container.mainContext.save()
        let authentication = MockAuthenticationService()
        try await authentication.resetCredentials()
        let coordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: MockSecureFileStorage(),
            modelContext: container.mainContext
        )

        await coordinator.initializeIfNeeded()

        XCTAssertEqual(coordinator.state, .recoveryRequired)
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

private actor TestAsyncCounter {
    private(set) var value = 0
    private var nextError: VaultError?

    init(nextError: VaultError? = nil) {
        self.nextError = nextError
    }

    func increment() throws {
        value += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
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
