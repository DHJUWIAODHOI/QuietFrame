import Foundation
@testable import QuietFrame

/// Forwards every call to other storage, usually real storage in a temporary directory, and counts the calls a
/// service makes.
actor CountingSecureFileStorage: SecureFileStoring {
    private(set) var moveCalls = 0
    private(set) var deleteCalls = 0
    private(set) var fileByteCountCalls = 0
    private(set) var fileByteCountsCalls = 0
    private let storage: any SecureFileStoring

    init(wrapping storage: any SecureFileStoring) {
        self.storage = storage
    }

    var totalCalls: Int {
        moveCalls + deleteCalls + fileByteCountCalls + fileByteCountsCalls
    }

    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile {
        try await storage.store(plaintextURL: plaintextURL, location: location, progress: progress)
    }

    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile {
        try await storage.store(plaintextData: plaintextData, location: location)
    }

    func decryptData(
        identifier: String,
        location: EncryptedAssetLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        try await storage.decryptData(identifier: identifier, location: location, maximumByteCount: maximumByteCount)
    }

    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease {
        try await storage.temporaryDecryptedFile(
            identifier: identifier,
            location: location,
            preferredExtension: preferredExtension
        )
    }

    func move(identifier: String, from: EncryptedAssetLocation, to: EncryptedAssetLocation) async throws {
        moveCalls += 1
        try await storage.move(identifier: identifier, from: from, to: to)
    }

    func delete(identifier: String, location: EncryptedAssetLocation) async throws {
        deleteCalls += 1
        try await storage.delete(identifier: identifier, location: location)
    }

    func cleanupTemporaryFiles() async {
        await storage.cleanupTemporaryFiles()
    }

    func removeAllEncryptedData() async throws {
        try await storage.removeAllEncryptedData()
    }

    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64 {
        fileByteCountCalls += 1
        return try await storage.fileByteCount(identifier: identifier, location: location)
    }

    func fileByteCounts(location: EncryptedAssetLocation) async throws -> [String: Int64] {
        fileByteCountsCalls += 1
        return try await storage.fileByteCounts(location: location)
    }

    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String> {
        try await storage.allIdentifiers(location: location)
    }

    func openEncryptedReader(identifier: String, location: EncryptedAssetLocation) async throws -> EncryptedFileReader {
        try await storage.openEncryptedReader(identifier: identifier, location: location)
    }
}
