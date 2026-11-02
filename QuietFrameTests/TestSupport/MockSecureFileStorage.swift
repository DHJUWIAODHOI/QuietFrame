import Foundation
@testable import QuietFrame

actor MockSecureFileStorage: SecureFileStoring {
    var cleanupCount = 0
    var moveCount = 0
    var deleteCount = 0
    var removeAllCount = 0
    var allIdentifiersCount = 0
    var identifiers: [EncryptedAssetLocation: Set<String>] = [:]
    private var shouldPauseNextMove = false
    private var isMovePaused = false
    private var pausedMoveContinuation: CheckedContinuation<Void, Never>?
    private var pausedMoveWaiters: [CheckedContinuation<Void, Never>] = []

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

    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile {
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
        identifiers[from, default: []].remove(identifier)
        identifiers[to, default: []].insert(identifier)
        guard shouldPauseNextMove else { return }
        shouldPauseNextMove = false
        await withCheckedContinuation { continuation in
            pausedMoveContinuation = continuation
            isMovePaused = true
            pausedMoveWaiters.forEach { $0.resume() }
            pausedMoveWaiters.removeAll()
        }
        isMovePaused = false
    }

    func delete(identifier: String, location: EncryptedAssetLocation) async throws {
        deleteCount += 1
        identifiers[location, default: []].remove(identifier)
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
        allIdentifiersCount += 1
        return identifiers[location] ?? []
    }

    func openEncryptedReader(identifier: String, location: EncryptedAssetLocation) async throws -> EncryptedFileReader {
        throw VaultError.fileOperationFailed
    }

    func pauseNextMove() {
        shouldPauseNextMove = true
    }

    func waitForPausedMove() async {
        guard !isMovePaused else { return }
        await withCheckedContinuation { pausedMoveWaiters.append($0) }
    }

    func resumePausedMove() {
        pausedMoveContinuation?.resume()
        pausedMoveContinuation = nil
    }
}
