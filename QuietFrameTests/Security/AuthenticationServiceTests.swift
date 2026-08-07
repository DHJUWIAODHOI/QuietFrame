import XCTest
@testable import QuietFrame

final class AuthenticationServiceTests: XCTestCase {
    func testCreateLockAndUnlockPasscode() async throws {
        let session = VaultSession()
        let service = AuthenticationService(
            keychain: MockKeychainService(),
            session: session,
            policy: .init(derivationIterations: 100, saltByteCount: 16)
        )

        try await service.createPasscode("135790")
        let unlockedAfterCreation = await session.isUnlocked
        XCTAssertTrue(unlockedAfterCreation)

        await service.lock()
        let unlockedAfterLock = await session.isUnlocked
        XCTAssertFalse(unlockedAfterLock)

        try await service.unlock(passcode: "135790")
        let unlockedAfterPasscode = await session.isUnlocked
        XCTAssertTrue(unlockedAfterPasscode)
    }

    func testWrongPasscodeDoesNotUnlockSession() async throws {
        let session = VaultSession()
        let service = AuthenticationService(
            keychain: MockKeychainService(),
            session: session,
            policy: .init(derivationIterations: 50, saltByteCount: 16)
        )
        try await service.createPasscode("246802")
        await service.lock()

        do {
            try await service.unlock(passcode: "111111")
            XCTFail("An incorrect passcode must not unlock the vault.")
        } catch {
            XCTAssertEqual(error as? VaultError, .invalidPasscode)
        }
        let isUnlocked = await session.isUnlocked
        XCTAssertFalse(isUnlocked)
    }

    func testFourthWrongAttemptCreatesLockout() async throws {
        let session = VaultSession()
        let service = AuthenticationService(
            keychain: MockKeychainService(),
            session: session,
            policy: .init(derivationIterations: 25, saltByteCount: 16)
        )
        try await service.createPasscode("123456")
        await service.lock()

        for _ in 0..<3 {
            do {
                try await service.unlock(passcode: "654321")
                XCTFail("An incorrect passcode must fail.")
            } catch VaultError.invalidPasscode {
                // Expected before the delay threshold.
            }
        }

        do {
            try await service.unlock(passcode: "654321")
            XCTFail("The fourth incorrect attempt must be delayed.")
        } catch VaultError.temporarilyLocked(let date) {
            XCTAssertGreaterThan(date, Date())
        }
    }

    func testChangePasscodeRewrapsSameVaultKey() async throws {
        let session = VaultSession()
        let service = AuthenticationService(
            keychain: MockKeychainService(),
            session: session,
            policy: .init(derivationIterations: 50, saltByteCount: 16)
        )
        try await service.createPasscode("123456")
        let originalKey = try await session.keyData()

        try await service.changePasscode(current: "123456", new: "987654")
        await service.lock()
        try await service.unlock(passcode: "987654")

        let unwrappedKey = try await session.keyData()
        XCTAssertEqual(unwrappedKey, originalKey)
    }
}
