import CryptoKit
import Foundation

actor VaultSession {
    struct KeyAccess {
        let key: SymmetricKey
        let generation: UInt64
    }

    private var masterKey: SymmetricKey?
    private var generation: UInt64 = 0

    var isUnlocked: Bool { masterKey != nil }

    func unlock(with keyData: Data) throws {
        guard keyData.count == 32 else { throw VaultError.missingEncryptionKey }
        generation &+= 1
        masterKey = SymmetricKey(data: keyData)
    }

    func unlock(with key: SymmetricKey) {
        generation &+= 1
        masterKey = key
    }

    func key() throws -> SymmetricKey {
        guard let masterKey else { throw VaultError.authenticationRequired }
        return masterKey
    }

    func keyData() throws -> Data {
        let key = try key()
        return key.withUnsafeBytes { Data($0) }
    }

    func keyAccess() throws -> KeyAccess {
        KeyAccess(key: try key(), generation: generation)
    }

    func validate(_ accessGeneration: UInt64) throws {
        guard masterKey != nil, generation == accessGeneration else {
            throw VaultError.authenticationRequired
        }
    }

    func lock() {
        generation &+= 1
        masterKey = nil
    }
}
