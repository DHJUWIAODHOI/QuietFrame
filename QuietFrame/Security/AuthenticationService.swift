import CryptoKit
import Foundation
import LocalAuthentication

enum BiometricKind: String, Sendable {
    case none
    case faceID
    case touchID

    var title: String {
        switch self {
        case .none: "Biometrics"
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        }
    }
}

protocol AuthenticationServicing: Sendable {
    func hasPasscode() async throws -> Bool
    func createPasscode(_ passcode: String) async throws
    func unlock(passcode: String) async throws
    func unlockWithBiometrics(reason: String) async throws
    func enableBiometrics() async throws
    func disableBiometrics() async throws
    func changePasscode(current: String, new: String) async throws
    func currentLockoutDate() async throws -> Date?
    func biometricKind() async -> BiometricKind
    func lock() async
    func resetCredentials() async throws
    func authorizeDestructiveReset() async throws
}

actor AuthenticationService: AuthenticationServicing {
    struct Policy: Sendable {
        let derivationIterations: Int
        let saltByteCount: Int

        static let production = Policy(derivationIterations: 210_000, saltByteCount: 16)
    }

    private struct PasscodeEnvelope: Codable {
        let version: Int
        let salt: Data
        let iterations: Int
        let verifier: Data
        let sealedMasterKey: Data
    }

    private struct AttemptState: Codable {
        var failedCount: Int
        var blockedUntil: Date?
    }

    private enum Account {
        static let passcodeEnvelope = "passcode-envelope-v1"
        static let biometricMasterKey = "biometric-master-key-v1"
        static let attemptState = "attempt-state-v1"
    }

    private let keychain: any KeychainServing
    private let session: VaultSession
    private let policy: Policy
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        keychain: any KeychainServing,
        session: VaultSession,
        policy: Policy = .production,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.session = session
        self.policy = policy
        self.now = now
    }

    func hasPasscode() throws -> Bool {
        try keychain.data(for: Account.passcodeEnvelope) != nil
    }

    func createPasscode(_ passcode: String) async throws {
        try Self.validate(passcode)
        guard try !hasPasscode() else {
            throw VaultError.invalidInput("A passcode already exists.")
        }

        let masterKeyData = try Data.secureRandom(count: 32)
        let envelope = try makeEnvelope(passcode: passcode, masterKeyData: masterKeyData)
        try keychain.set(encoder.encode(envelope), account: Account.passcodeEnvelope)
        try? keychain.delete(account: Account.attemptState)
        try await session.unlock(with: masterKeyData)
    }

    func unlock(passcode: String) async throws {
        try Self.validate(passcode)
        if let blockedUntil = try currentLockoutDate(), blockedUntil > now() {
            throw VaultError.temporarilyLocked(until: blockedUntil)
        }

        guard let envelopeData = try keychain.data(for: Account.passcodeEnvelope) else {
            throw VaultError.missingEncryptionKey
        }

        let envelope: PasscodeEnvelope
        do {
            envelope = try decoder.decode(PasscodeEnvelope.self, from: envelopeData)
        } catch {
            throw VaultError.keychainFailure
        }

        do {
            let masterKeyData = try unwrapMasterKey(passcode: passcode, envelope: envelope)
            try await session.unlock(with: masterKeyData)
            try? keychain.delete(account: Account.attemptState)
        } catch VaultError.invalidPasscode {
            let lockout = try recordFailedAttempt()
            if let lockout { throw VaultError.temporarilyLocked(until: lockout) }
            throw VaultError.invalidPasscode
        }
    }

    func unlockWithBiometrics(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Use Passcode"
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError) else {
            throw mapBiometricError(evaluationError)
        }

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            guard authenticated else { throw VaultError.authenticationFailed }
            guard let keyData = try keychain.biometricProtectedData(
                account: Account.biometricMasterKey,
                context: context
            ) else {
                throw VaultError.biometricsChanged
            }
            try await session.unlock(with: keyData)
            try? keychain.delete(account: Account.attemptState)
        } catch let error as VaultError {
            throw error
        } catch {
            throw mapBiometricError(error as NSError)
        }
    }

    func enableBiometrics() async throws {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError) else {
            throw mapBiometricError(evaluationError)
        }
        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Enable biometric unlock for QuietFrame"
            ) else {
                throw VaultError.authenticationFailed
            }
        } catch {
            throw mapBiometricError(error as NSError)
        }
        let keyData = try await session.keyData()
        try keychain.setBiometricProtected(keyData, account: Account.biometricMasterKey)
    }

    func disableBiometrics() throws {
        try keychain.delete(account: Account.biometricMasterKey)
    }

    func changePasscode(current: String, new: String) async throws {
        try Self.validate(new)
        if let blockedUntil = try currentLockoutDate(), blockedUntil > now() {
            throw VaultError.temporarilyLocked(until: blockedUntil)
        }
        guard let envelopeData = try keychain.data(for: Account.passcodeEnvelope),
              let envelope = try? decoder.decode(PasscodeEnvelope.self, from: envelopeData) else {
            throw VaultError.missingEncryptionKey
        }

        let masterKeyData: Data
        do {
            masterKeyData = try unwrapMasterKey(passcode: current, envelope: envelope)
        } catch VaultError.invalidPasscode {
            let lockout = try recordFailedAttempt()
            if let lockout { throw VaultError.temporarilyLocked(until: lockout) }
            throw VaultError.invalidPasscode
        }

        let replacement = try makeEnvelope(passcode: new, masterKeyData: masterKeyData)
        try keychain.set(encoder.encode(replacement), account: Account.passcodeEnvelope)
        try? keychain.delete(account: Account.attemptState)
        try await session.unlock(with: masterKeyData)
    }

    func currentLockoutDate() throws -> Date? {
        guard let data = try keychain.data(for: Account.attemptState),
              let state = try? decoder.decode(AttemptState.self, from: data),
              let blockedUntil = state.blockedUntil,
              blockedUntil > now() else {
            return nil
        }
        return blockedUntil
    }

    func biometricKind() -> BiometricKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .none
        case .none: return .none
        @unknown default: return .none
        }
    }

    func lock() async {
        await session.lock()
    }

    func resetCredentials() async throws {
        await session.lock()
        try keychain.delete(account: Account.biometricMasterKey)
        try keychain.delete(account: Account.passcodeEnvelope)
        try keychain.delete(account: Account.attemptState)
    }

    func authorizeDestructiveReset() async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw VaultError.authenticationFailed
        }
        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to permanently erase the unrecoverable QuietFrame vault"
            ) else {
                throw VaultError.authenticationFailed
            }
        } catch {
            throw VaultError.authenticationFailed
        }
    }

    private static func validate(_ passcode: String) throws {
        guard passcode.count == 6, passcode.allSatisfy({ character in
            character >= "0" && character <= "9"
        }) else {
            throw VaultError.invalidPasscode
        }
    }

    private func makeEnvelope(passcode: String, masterKeyData: Data) throws -> PasscodeEnvelope {
        let salt = try Data.secureRandom(count: policy.saltByteCount)
        let passcodeData = Data(passcode.utf8)
        let wrappingKey = try PBKDF2.deriveSHA256Key(
            password: passcodeData,
            salt: salt,
            iterations: policy.derivationIterations
        )
        let verifier = Data(HMAC<SHA256>.authenticationCode(
            for: Data("QuietFrame.passcode.verifier.v1".utf8),
            using: wrappingKey
        ))
        let sealed = try AES.GCM.seal(
            masterKeyData,
            using: wrappingKey,
            authenticating: Data("QuietFrame.master-key.v1".utf8)
        )
        guard let combined = sealed.combined else { throw VaultError.keychainFailure }
        return PasscodeEnvelope(
            version: 1,
            salt: salt,
            iterations: policy.derivationIterations,
            verifier: verifier,
            sealedMasterKey: combined
        )
    }

    private func unwrapMasterKey(passcode: String, envelope: PasscodeEnvelope) throws -> Data {
        guard envelope.version == 1,
              envelope.iterations > 0,
              envelope.iterations <= 2_000_000,
              envelope.salt.count >= 16,
              envelope.salt.count <= 64,
              envelope.verifier.count == SHA256.Digest.byteCount,
              envelope.sealedMasterKey.count >= 60 else {
            throw VaultError.keychainFailure
        }
        let wrappingKey = try PBKDF2.deriveSHA256Key(
            password: Data(passcode.utf8),
            salt: envelope.salt,
            iterations: envelope.iterations
        )
        let candidateVerifier = Data(HMAC<SHA256>.authenticationCode(
            for: Data("QuietFrame.passcode.verifier.v1".utf8),
            using: wrappingKey
        ))
        guard candidateVerifier.constantTimeEquals(envelope.verifier) else {
            throw VaultError.invalidPasscode
        }

        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedMasterKey)
            let data = try AES.GCM.open(
                box,
                using: wrappingKey,
                authenticating: Data("QuietFrame.master-key.v1".utf8)
            )
            guard data.count == 32 else { throw VaultError.missingEncryptionKey }
            return data
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.keychainFailure
        }
    }

    private func recordFailedAttempt() throws -> Date? {
        let currentData = try keychain.data(for: Account.attemptState)
        var state = currentData.flatMap { try? decoder.decode(AttemptState.self, from: $0) }
            ?? AttemptState(failedCount: 0, blockedUntil: nil)
        state.failedCount += 1

        let delays: [TimeInterval] = [0, 0, 0, 1, 2, 5, 15, 30, 60, 300, 900, 3_600]
        let index = min(state.failedCount - 1, delays.count - 1)
        let delay = delays[index]
        state.blockedUntil = delay > 0 ? now().addingTimeInterval(delay) : nil
        try keychain.set(encoder.encode(state), account: Account.attemptState)
        return state.blockedUntil
    }

    private func mapBiometricError(_ error: NSError?) -> VaultError {
        guard let error, error.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: error.code) else {
            return .authenticationFailed
        }
        switch code {
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            return .biometricsUnavailable
        case .biometryLockout:
            return .temporarilyLocked(until: now().addingTimeInterval(30))
        default:
            return .authenticationFailed
        }
    }
}
