import Foundation
import LocalAuthentication
@testable import QuietFrame

final class MockKeychainService: KeychainServing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func set(_ data: Data, account: String) throws {
        lock.lock()
        storage[account] = data
        lock.unlock()
    }

    func data(for account: String) throws -> Data? {
        lock.lock()
        let data = storage[account]
        lock.unlock()
        return data
    }

    func delete(account: String) throws {
        lock.lock()
        storage.removeValue(forKey: account)
        lock.unlock()
    }

    func setBiometricProtected(_ data: Data, account: String) throws {
        try set(data, account: account)
    }

    func biometricProtectedData(account: String, context: LAContext) throws -> Data? {
        try data(for: account)
    }
}
