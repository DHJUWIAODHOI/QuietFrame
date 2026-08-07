import Foundation
import LocalAuthentication
import Security

protocol KeychainServing: Sendable {
    func set(_ data: Data, account: String) throws
    func data(for account: String) throws -> Data?
    func delete(account: String) throws
    func setBiometricProtected(_ data: Data, account: String) throws
    func biometricProtectedData(account: String, context: LAContext) throws -> Data?
}

final class KeychainService: KeychainServing, @unchecked Sendable {
    private let service: String

    init(service: String = "com.quietframe.vault.security") {
        self.service = service
    }

    func set(_ data: Data, account: String) throws {
        let existingQuery = baseQuery(account: account)
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(existingQuery as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw VaultError.keychainFailure }

        var newItem = existingQuery
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw VaultError.keychainFailure }
    }

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VaultError.keychainFailure
        }
        return data
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychainFailure
        }
    }

    func setBiometricProtected(_ data: Data, account: String) throws {
        try delete(account: account)
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            throw VaultError.biometricsUnavailable
        }

        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = accessControl
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainFailure }
    }

    func biometricProtectedData(account: String, context: LAContext) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status == errSecAuthFailed { throw VaultError.biometricsChanged }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VaultError.keychainFailure
        }
        return data
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
