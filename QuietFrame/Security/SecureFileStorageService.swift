import Foundation

enum EncryptedAssetLocation: String, Codable, Hashable, Sendable {
    case media
    case thumbnails
    case trash
}

struct StoredEncryptedFile: Sendable, Equatable {
    let identifier: String
    let result: EncryptionResult
}

struct EncryptedFileReference: Hashable, Sendable {
    let identifier: String
    let location: EncryptedAssetLocation
}

struct EncryptedFileMoveResult: Sendable {
    /// The files moved before the first failure, in order.
    let moved: [String]
    /// The error the failing move threw, unchanged.
    let failure: (any Error)?
}

protocol SecureFileStoring: Sendable {
    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile
    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile
    func decryptData(identifier: String, location: EncryptedAssetLocation, maximumByteCount: Int) async throws -> Data
    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease
    func move(identifier: String, from: EncryptedAssetLocation, to: EncryptedAssetLocation) async throws
    /// Moves the files in order and stops at the first failure, leaving the files already moved where they are.
    func move(
        identifiers: [String],
        from: EncryptedAssetLocation,
        to: EncryptedAssetLocation
    ) async -> EncryptedFileMoveResult
    func delete(identifier: String, location: EncryptedAssetLocation) async throws
    /// Deletes each item's files in order. A failure skips the rest of that item only. Returns how many items failed.
    func deleteFiles(ofItems items: [[EncryptedFileReference]]) async -> Int
    func cleanupTemporaryFiles() async
    func removeAllEncryptedData() async throws
    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64
    /// Sizes from one directory listing, keyed by identifier. Files it leaves out are measured with `fileByteCount`.
    func fileByteCounts(location: EncryptedAssetLocation) async throws -> [String: Int64]
    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String>
    func openEncryptedReader(identifier: String, location: EncryptedAssetLocation) async throws -> EncryptedFileReader
}

extension SecureFileStoring {
    func move(
        identifiers: [String],
        from source: EncryptedAssetLocation,
        to destination: EncryptedAssetLocation
    ) async -> EncryptedFileMoveResult {
        var moved: [String] = []
        for identifier in identifiers {
            do {
                try await move(identifier: identifier, from: source, to: destination)
            } catch {
                return EncryptedFileMoveResult(moved: moved, failure: error)
            }
            moved.append(identifier)
        }
        return EncryptedFileMoveResult(moved: moved, failure: nil)
    }

    func deleteFiles(ofItems items: [[EncryptedFileReference]]) async -> Int {
        var failedItemCount = 0
        for files in items {
            do {
                for file in files {
                    try await delete(identifier: file.identifier, location: file.location)
                }
            } catch {
                failedItemCount += 1
            }
        }
        return failedItemCount
    }

    func fileByteCounts(location: EncryptedAssetLocation) async throws -> [String: Int64] {
        [:]
    }
}

actor SecureFileStorageService: SecureFileStoring {
    private let fileManager: FileManager
    private let encryption: any FileEncrypting
    private let rootURL: URL
    private let stagingURL: URL
    private let temporaryURL: URL
    private let applyFileProtection: Bool

    init(
        encryption: any FileEncrypting,
        fileManager: FileManager = .default,
        baseURL: URL? = nil,
        temporaryBaseURL: URL? = nil,
        applyFileProtection: Bool = true
    ) throws {
        self.fileManager = fileManager
        self.encryption = encryption
        self.applyFileProtection = applyFileProtection

        let applicationSupport: URL
        if let baseURL {
            applicationSupport = baseURL
        } else {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let caches: URL
        if let temporaryBaseURL {
            caches = temporaryBaseURL
        } else {
            caches = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        rootURL = applicationSupport.appendingPathComponent("QuietFrameVault", isDirectory: true)
        stagingURL = rootURL.appendingPathComponent("staging", isDirectory: true)
        temporaryURL = caches.appendingPathComponent("QuietFrameTemporary", isDirectory: true)

        try Self.prepareDirectory(rootURL, fileManager: fileManager, applyFileProtection: applyFileProtection)
        try Self.prepareDirectory(stagingURL, fileManager: fileManager, applyFileProtection: applyFileProtection)
        try Self.prepareDirectory(temporaryURL, fileManager: fileManager, applyFileProtection: applyFileProtection)
        for location in [EncryptedAssetLocation.media, .thumbnails, .trash] {
            try Self.prepareDirectory(
                rootURL.appendingPathComponent(location.rawValue, isDirectory: true),
                fileManager: fileManager,
                applyFileProtection: applyFileProtection
            )
        }
    }

    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler? = nil
    ) async throws -> StoredEncryptedFile {
        try await storeEncryptedFile(in: location) { partialURL in
            try await encryption.encryptFile(at: plaintextURL, to: partialURL, progress: progress)
        }
    }

    /// Encrypts bytes held in memory, such as a thumbnail, without writing them to disk unencrypted first.
    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile {
        try await storeEncryptedFile(in: location) { partialURL in
            try await encryption.encryptData(plaintextData, to: partialURL)
        }
    }

    private func storeEncryptedFile(
        in location: EncryptedAssetLocation,
        encrypt: (URL) async throws -> EncryptionResult
    ) async throws -> StoredEncryptedFile {
        let identifier = UUID().uuidString.lowercased()
        let partialURL = stagingURL.appendingPathComponent("\(identifier).partial")
        let finalURL = try encryptedURL(identifier: identifier, location: location)

        do {
            let result = try await encrypt(partialURL)
            try protectAndExcludeFromBackup(partialURL)
            try fileManager.moveItem(at: partialURL, to: finalURL)
            try protectAndExcludeFromBackup(finalURL)
            return StoredEncryptedFile(identifier: identifier, result: result)
        } catch {
            try? fileManager.removeItem(at: partialURL)
            try? fileManager.removeItem(at: finalURL)
            throw error
        }
    }

    /// Runs off the actor, so thumbnail and viewer reads never wait behind other storage work.
    nonisolated func decryptData(
        identifier: String,
        location: EncryptedAssetLocation,
        maximumByteCount: Int = 268_435_456
    ) async throws -> Data {
        let url = try encryptedURL(identifier: identifier, location: location)
        guard fileManager.fileExists(atPath: url.path) else { throw VaultError.corruptedFile }
        return try await encryption.decryptData(at: url, maximumByteCount: maximumByteCount)
    }

    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease {
        let encryptedURL = try encryptedURL(identifier: identifier, location: location)
        guard fileManager.fileExists(atPath: encryptedURL.path) else { throw VaultError.corruptedFile }

        let encryptedAttributes = try fileManager.attributesOfItem(atPath: encryptedURL.path)
        let encryptedByteCount = (encryptedAttributes[.size] as? NSNumber)?.int64Value ?? 0
        let capacityValues = try temporaryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let available = capacityValues.volumeAvailableCapacityForImportantUsage {
            let safetyMargin: Int64 = 32 * 1_024 * 1_024
            guard available > encryptedByteCount + safetyMargin else {
                throw VaultError.insufficientStorage
            }
        }

        let fileExtension = Self.safeExtension(preferredExtension)
        let filename = UUID().uuidString.lowercased() + (fileExtension.map { ".\($0)" } ?? "")
        let outputURL = temporaryURL.appendingPathComponent(filename)
        do {
            try await encryption.decryptFile(at: encryptedURL, to: outputURL, progress: nil)
            try protectAndExcludeFromBackup(outputURL)
            return SecureTemporaryFileLease(url: outputURL) { url in
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    /// Reads an encrypted file in place, decrypting only the ranges asked for; nothing is written to disk.
    func openEncryptedReader(identifier: String, location: EncryptedAssetLocation) async throws -> EncryptedFileReader {
        let url = try encryptedURL(identifier: identifier, location: location)
        guard fileManager.fileExists(atPath: url.path) else { throw VaultError.corruptedFile }
        return try await encryption.openReader(at: url)
    }

    func move(
        identifier: String,
        from source: EncryptedAssetLocation,
        to destination: EncryptedAssetLocation
    ) throws {
        guard source != destination else { return }
        let sourceURL = try encryptedURL(identifier: identifier, location: source)
        let destinationURL = try encryptedURL(identifier: identifier, location: destination)
        guard fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path) else {
            throw VaultError.fileOperationFailed
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        do {
            try protectAndExcludeFromBackup(destinationURL)
        } catch {
            try? fileManager.moveItem(at: destinationURL, to: sourceURL)
            throw error
        }
    }

    /// Bulk moves and deletes let other work on this actor, such as thumbnail decrypts and the lock's cleanup, run
    /// after this many files instead of waiting for the whole batch.
    private static let batchYieldInterval = 32

    func move(
        identifiers: [String],
        from source: EncryptedAssetLocation,
        to destination: EncryptedAssetLocation
    ) async -> EncryptedFileMoveResult {
        var moved: [String] = []
        moved.reserveCapacity(identifiers.count)
        for (offset, identifier) in identifiers.enumerated() {
            if offset > 0, offset.isMultiple(of: Self.batchYieldInterval) {
                await Task.yield()
            }
            do {
                try move(identifier: identifier, from: source, to: destination)
            } catch {
                return EncryptedFileMoveResult(moved: moved, failure: error)
            }
            moved.append(identifier)
        }
        return EncryptedFileMoveResult(moved: moved, failure: nil)
    }

    func delete(identifier: String, location: EncryptedAssetLocation) throws {
        let url = try encryptedURL(identifier: identifier, location: location)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteFiles(ofItems items: [[EncryptedFileReference]]) async -> Int {
        var failedItemCount = 0
        for (offset, files) in items.enumerated() {
            if offset > 0, offset.isMultiple(of: Self.batchYieldInterval) {
                await Task.yield()
            }
            do {
                for file in files {
                    try delete(identifier: file.identifier, location: file.location)
                }
            } catch {
                failedItemCount += 1
            }
        }
        return failedItemCount
    }

    func cleanupTemporaryFiles() {
        for directory in [temporaryURL, stagingURL] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func removeAllEncryptedData() throws {
        cleanupTemporaryFiles()
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try Self.prepareDirectory(rootURL, fileManager: fileManager, applyFileProtection: applyFileProtection)
        try Self.prepareDirectory(stagingURL, fileManager: fileManager, applyFileProtection: applyFileProtection)
        for location in [EncryptedAssetLocation.media, .thumbnails, .trash] {
            try Self.prepareDirectory(
                rootURL.appendingPathComponent(location.rawValue, isDirectory: true),
                fileManager: fileManager,
                applyFileProtection: applyFileProtection
            )
        }
    }

    func fileByteCount(identifier: String, location: EncryptedAssetLocation) throws -> Int64 {
        let url = try encryptedURL(identifier: identifier, location: location)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Only regular files with a vault file's name are listed; anything else, such as a directory with such a name,
    /// is left to `fileByteCount`, so callers get the same size or the same error as before.
    func fileByteCounts(location: EncryptedAssetLocation) throws -> [String: Int64] {
        let directory = rootURL.appendingPathComponent(location.rawValue, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var sizes: [String: Int64] = [:]
        sizes.reserveCapacity(urls.count)
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), name.hasSuffix(".qfe") else { continue }
            let identifier = String(name.dropLast(4))
            guard UUID(uuidString: identifier) != nil else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            sizes[identifier] = Int64(size)
        }
        return sizes
    }

    func allIdentifiers(location: EncryptedAssetLocation) throws -> Set<String> {
        let directory = rootURL.appendingPathComponent(location.rawValue, isDirectory: true)
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        return Set(names.compactMap { name in
            guard !name.hasPrefix("."), name.hasSuffix(".qfe") else { return nil }
            let identifier = String(name.dropLast(4))
            return UUID(uuidString: identifier) == nil ? nil : identifier
        })
    }

    private nonisolated func encryptedURL(identifier: String, location: EncryptedAssetLocation) throws -> URL {
        guard UUID(uuidString: identifier) != nil else { throw VaultError.fileOperationFailed }
        return rootURL
            .appendingPathComponent(location.rawValue, isDirectory: true)
            .appendingPathComponent("\(identifier).qfe", isDirectory: false)
    }

    private func protectAndExcludeFromBackup(_ url: URL) throws {
        if applyFileProtection {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        }
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func prepareDirectory(
        _ url: URL,
        fileManager: FileManager,
        applyFileProtection: Bool
    ) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        if applyFileProtection {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        }
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func safeExtension(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let value = candidate.lowercased().filter { character in
            (character >= "a" && character <= "z") || (character >= "0" && character <= "9")
        }
        guard !value.isEmpty else { return nil }
        return String(value.prefix(8))
    }
}
