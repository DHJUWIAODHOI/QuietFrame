import Foundation
@testable import QuietFrame

/// Serves plaintext thumbnails from memory and counts decrypts. While held, decrypts wait until released.
actor ThumbnailStorageFake: SecureFileStoring {
    private var payloads: [String: Data]
    private(set) var decryptCount = 0
    private var isHolding = false
    private var heldDecrypts: [CheckedContinuation<Void, Never>] = []

    init(payloads: [String: Data] = [:]) {
        self.payloads = payloads
    }

    var heldDecryptCount: Int {
        heldDecrypts.count
    }

    func setPayload(_ data: Data?, for identifier: String) {
        payloads[identifier] = data
    }

    func holdDecrypts() {
        isHolding = true
    }

    func releaseDecrypts() {
        isHolding = false
        heldDecrypts.forEach { $0.resume() }
        heldDecrypts.removeAll()
    }

    func decryptData(
        identifier: String,
        location: EncryptedAssetLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        decryptCount += 1
        if isHolding {
            await withCheckedContinuation { heldDecrypts.append($0) }
        }
        try Task.checkCancellation()
        guard let data = payloads[identifier] else { throw VaultError.corruptedFile }
        return data
    }

    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile {
        throw VaultError.fileOperationFailed
    }

    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile {
        throw VaultError.fileOperationFailed
    }

    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease {
        throw VaultError.fileOperationFailed
    }

    func move(identifier: String, from: EncryptedAssetLocation, to: EncryptedAssetLocation) async throws {}

    func delete(identifier: String, location: EncryptedAssetLocation) async throws {}

    func cleanupTemporaryFiles() async {}

    func removeAllEncryptedData() async throws {}

    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64 {
        Int64(payloads[identifier]?.count ?? 0)
    }

    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String> {
        Set(payloads.keys)
    }
}
