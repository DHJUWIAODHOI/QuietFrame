import Foundation
@testable import QuietFrame

actor MockAuthenticationService: AuthenticationServicing {
    var passcodeExists = true
    var mode: VaultAuthenticationMode = .passcode
    var lockCount = 0
    var unlockWithoutPasscodeCount = 0
    var nextError: VaultError?

    private let session: VaultSession?
    private let keyData: Data

    init(
        session: VaultSession? = nil,
        keyData: Data = Data(repeating: 0x5a, count: 32)
    ) {
        self.session = session
        self.keyData = keyData
    }

    func authenticationMode() async throws -> VaultAuthenticationMode { mode }

    func hasPasscode() async throws -> Bool { passcodeExists }

    func createPasscode(_ passcode: String) async throws {
        if let nextError { throw nextError }
        passcodeExists = true
        mode = .passcode
    }

    func createWithoutPasscode() async throws {
        if let nextError { throw nextError }
        passcodeExists = false
        mode = .none
    }

    func unlockWithoutPasscode() async throws {
        unlockWithoutPasscodeCount += 1
        if let nextError { throw nextError }
        if let session { try await session.unlock(with: keyData) }
    }

    func addPasscode(_ passcode: String) async throws {
        if let nextError { throw nextError }
        passcodeExists = true
        mode = .passcode
    }

    func removePasscode(current: String) async throws {
        if let nextError { throw nextError }
        passcodeExists = false
        mode = .none
    }

    func unlock(passcode: String) async throws {
        if let nextError { throw nextError }
    }

    func unlockWithBiometrics(reason: String) async throws {
        if let nextError { throw nextError }
    }

    func enableBiometrics() async throws {
        if let nextError { throw nextError }
    }

    func disableBiometrics() async throws {
        if let nextError { throw nextError }
    }

    func changePasscode(current: String, new: String) async throws {
        if let nextError { throw nextError }
    }

    func currentLockoutDate() async throws -> Date? { nil }
    func biometricKind() async -> BiometricKind { .faceID }

    func lock() async {
        lockCount += 1
    }

    func resetCredentials() async throws {
        passcodeExists = false
        mode = .notConfigured
    }

    func authorizeDestructiveReset() async throws {
        if let nextError { throw nextError }
    }
}
