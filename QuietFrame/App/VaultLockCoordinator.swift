import Foundation
import Observation
import SwiftData

enum AppLifecycleEvent: Sendable {
    case active
    case inactive
    case background
}

@MainActor
@Observable
final class VaultLockCoordinator {
    enum State: Equatable {
        case loading
        case needsOnboarding
        case locked
        case unlocked
        case recoveryRequired
    }

    private(set) var state: State = .loading
    private(set) var biometricKind: BiometricKind = .none
    private(set) var lockoutDate: Date?
    private(set) var isWorking = false
    var userMessage: String?

    private let authentication: any AuthenticationServicing
    private let secureStorage: any SecureFileStoring
    private let cancelMediaOperations: (@Sendable () async -> Void)?
    private let postUnlockMaintenance: (@Sendable () async throws -> Void)?
    private let modelContext: ModelContext
    private let now: @Sendable () -> Date
    private var backgroundedAt: Date?
    private var delayedLockTask: Task<Void, Never>?
    private var didInitialize = false

    init(
        authentication: any AuthenticationServicing,
        secureStorage: any SecureFileStoring,
        modelContext: ModelContext,
        cancelMediaOperations: (@Sendable () async -> Void)? = nil,
        postUnlockMaintenance: (@Sendable () async throws -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authentication = authentication
        self.secureStorage = secureStorage
        self.modelContext = modelContext
        self.cancelMediaOperations = cancelMediaOperations
        self.postUnlockMaintenance = postUnlockMaintenance
        self.now = now
    }

    var biometricsEnabled: Bool {
        settings()?.biometricsEnabled == true
    }

    var biometricButtonTitle: String {
        "Unlock with \(biometricKind.title)"
    }

    func initializeIfNeeded() async {
        guard !didInitialize else { return }
        didInitialize = true
        await secureStorage.cleanupTemporaryFiles()
        biometricKind = await authentication.biometricKind()

        do {
            lockoutDate = try await authentication.currentLockoutDate()
            if try await authentication.hasPasscode() {
                state = .locked
            } else if try hasPersistedMedia() {
                state = .recoveryRequired
                userMessage = VaultError.missingEncryptionKey.localizedDescription
            } else {
                state = .needsOnboarding
            }
        } catch {
            state = .recoveryRequired
            userMessage = userFacingMessage(for: error)
        }
    }

    func createPasscode(_ passcode: String, confirmation: String) async {
        guard passcode == confirmation else {
            userMessage = VaultError.passcodesDoNotMatch.localizedDescription
            return
        }
        await perform {
            try await authentication.createPasscode(passcode)
            state = .locked
            try await postUnlockMaintenance?()
            state = .unlocked
        }
    }

    func unlock(passcode: String) async {
        await perform {
            try await authentication.unlock(passcode: passcode)
            try await postUnlockMaintenance?()
            lockoutDate = nil
            state = .unlocked
        }
    }

    func unlockWithBiometrics() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await authentication.unlockWithBiometrics(
                reason: "Unlock your private QuietFrame library"
            )
            try await postUnlockMaintenance?()
            lockoutDate = nil
            state = .unlocked
            userMessage = nil
        } catch VaultError.biometricsChanged {
            await authentication.lock()
            if let settings = settings() {
                settings.biometricsEnabled = false
                try? modelContext.save()
            }
            try? await authentication.disableBiometrics()
            handleAuthenticationError(VaultError.biometricsChanged)
        } catch {
            await authentication.lock()
            handleAuthenticationError(error)
        }
    }

    func lock() async {
        delayedLockTask?.cancel()
        delayedLockTask = nil
        if state != .needsOnboarding && state != .recoveryRequired {
            state = .locked
        }
        await authentication.lock()
        await cancelMediaOperations?()
        await secureStorage.cleanupTemporaryFiles()
        userMessage = nil
        lockoutDate = try? await authentication.currentLockoutDate()
    }

    func setBiometricsEnabled(_ enabled: Bool) async -> Bool {
        do {
            guard let settings = settings() else { throw VaultError.persistenceFailure }
            if enabled {
                guard biometricKind != .none else { throw VaultError.biometricsUnavailable }
                try await authentication.enableBiometrics()
                settings.biometricsEnabled = true
                settings.modifiedAt = now()
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    try? await authentication.disableBiometrics()
                    throw VaultError.persistenceFailure
                }
            } else {
                settings.biometricsEnabled = false
                settings.modifiedAt = now()
                do {
                    try modelContext.save()
                    try await authentication.disableBiometrics()
                } catch {
                    settings.biometricsEnabled = true
                    settings.modifiedAt = now()
                    try? modelContext.save()
                    throw error
                }
            }
            userMessage = nil
            return true
        } catch {
            userMessage = userFacingMessage(for: error)
            return false
        }
    }

    func changePasscode(current: String, new: String, confirmation: String) async -> Bool {
        guard new == confirmation else {
            userMessage = VaultError.passcodesDoNotMatch.localizedDescription
            return false
        }
        do {
            try await authentication.changePasscode(current: current, new: new)
            userMessage = nil
            return true
        } catch {
            handleAuthenticationError(error)
            return false
        }
    }

    func resetApplication(passcode: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await authentication.unlock(passcode: passcode)
            try await eraseLocalVault()
            return true
        } catch {
            state = .recoveryRequired
            handleAuthenticationError(error)
            return false
        }
    }

    func resetUnrecoverableApplication() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await authentication.authorizeDestructiveReset()
            try await eraseLocalVault()
            return true
        } catch {
            state = .recoveryRequired
            handleAuthenticationError(error)
            return false
        }
    }

    func handleLifecycle(_ event: AppLifecycleEvent) async {
        switch event {
        case .inactive:
            if state == .unlocked, !isWorking, backgroundedAt == nil {
                backgroundedAt = now()
            }
        case .background:
            guard state == .unlocked else { return }
            if backgroundedAt == nil { backgroundedAt = now() }
            delayedLockTask?.cancel()
            let delay = settings()?.autoLockPeriod.rawValue ?? 0
            if delay == 0 {
                await lock()
            } else {
                delayedLockTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        await self?.lock()
                    } catch {
                        return
                    }
                }
            }
        case .active:
            delayedLockTask?.cancel()
            delayedLockTask = nil
            defer { backgroundedAt = nil }
            guard state == .unlocked,
                  let backgroundedAt else { return }
            let delay = TimeInterval(settings()?.autoLockPeriod.rawValue ?? 0)
            if now().timeIntervalSince(backgroundedAt) >= delay {
                await lock()
            }
        }
    }

    func clearMessage() {
        userMessage = nil
    }

    func clearExpiredLockoutIfNeeded() {
        guard let lockoutDate, lockoutDate <= now() else { return }
        self.lockoutDate = nil
        if userMessage?.contains("Too many attempts") == true {
            userMessage = nil
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            userMessage = nil
        } catch {
            await authentication.lock()
            handleAuthenticationError(error)
        }
    }

    private func handleAuthenticationError(_ error: Error) {
        if case VaultError.temporarilyLocked(let date) = error {
            lockoutDate = date
        }
        userMessage = userFacingMessage(for: error)
    }

    private func userFacingMessage(for error: Error) -> String {
        (error as? VaultError)?.localizedDescription
            ?? VaultError.authenticationFailed.localizedDescription
    }

    private func settings() -> AppSettings? {
        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func hasPersistedMedia() throws -> Bool {
        var descriptor = FetchDescriptor<VaultMedia>()
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func eraseLocalVault() async throws {
        try AppResetJournal.begin()
        state = .locked
        await authentication.lock()
        await cancelMediaOperations?()
        try await authentication.resetCredentials()
        try await secureStorage.removeAllEncryptedData()

        let media = try modelContext.fetch(FetchDescriptor<VaultMedia>())
        let albums = try modelContext.fetch(FetchDescriptor<VaultAlbum>())
        let imports = try modelContext.fetch(FetchDescriptor<ImportRecord>())
        let settings = try modelContext.fetch(FetchDescriptor<AppSettings>())
        media.forEach { modelContext.delete($0) }
        albums.forEach { modelContext.delete($0) }
        imports.forEach { modelContext.delete($0) }
        settings.forEach { modelContext.delete($0) }
        modelContext.insert(AppSettings())
        try modelContext.save()

        try AppResetJournal.finish()
        lockoutDate = nil
        userMessage = nil
        state = .needsOnboarding
    }
}
