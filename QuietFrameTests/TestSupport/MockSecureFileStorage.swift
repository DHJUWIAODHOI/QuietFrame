import Foundation
@testable import QuietFrame

actor MockSecureFileStorage: SecureFileStoring {
    var cleanupCount = 0
    var moveCount = 0
    var deleteCount = 0
    var removeAllCount = 0
    var identifiers: [EncryptedAssetLocation: Set<String>] = [:]

    init(identifiers: [EncryptedAssetLocation: Set<String>] = [:]) {
        self.identifiers = identifiers
    }

    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile {
        throw VaultError.fileOperationFailed
    }

    func decryptData(
        identifier: String,
        location: EncryptedAssetLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        throw VaultError.fileOperationFailed
    }

    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease {
        throw VaultError.fileOperationFailed
    }

    func move(
        identifier: String,
        from: EncryptedAssetLocation,
        to: EncryptedAssetLocation
    ) async throws {
        moveCount += 1
    }

    func delete(identifier: String, location: EncryptedAssetLocation) async throws {
        deleteCount += 1
    }

    func cleanupTemporaryFiles() async {
        cleanupCount += 1
    }

    func removeAllEncryptedData() async throws {
        removeAllCount += 1
        identifiers.removeAll()
    }

    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64 {
        1_024
    }

    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String> {
        identifiers[location] ?? []
    }
}
