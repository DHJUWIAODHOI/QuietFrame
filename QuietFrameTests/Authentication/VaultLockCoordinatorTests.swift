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
