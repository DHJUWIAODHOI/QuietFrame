import Foundation
@testable import QuietFrame

actor MockAuthenticationService: AuthenticationServicing {
    var passcodeExists = true
    var mode: VaultAuthenticationMode = .passcode
    var lockCount = 0
    var nextError: VaultError?

    func setNextError(_ error: VaultError?) {
        nextError = error
    }

    func authenticationMode() async throws -> VaultAuthenticationMode {
        if let nextError { throw nextError }
        return mode
    }

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
        if let nextError { throw nextError }
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
