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

protocol SecureFileStoring: Sendable {
    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile
    func decryptData(identifier: String, location: EncryptedAssetLocation, maximumByteCount: Int) async throws -> Data
    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease
    func move(identifier: String, from: EncryptedAssetLocation, to: EncryptedAssetLocation) async throws
    func delete(identifier: String, location: EncryptedAssetLocation) async throws
    func cleanupTemporaryFiles() async
    func removeAllEncryptedData() async throws
    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64
    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String>
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
        let identifier = UUID().uuidString.lowercased()
        let partialURL = stagingURL.appendingPathComponent("\(identifier).partial")
        let finalURL = try encryptedURL(identifier: identifier, location: location)

        do {
            let result = try await encryption.encryptFile(
                at: plaintextURL,
                to: partialURL,
                progress: progress
            )
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

    func decryptData(
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

    func delete(identifier: String, location: EncryptedAssetLocation) throws {
        let url = try encryptedURL(identifier: identifier, location: location)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
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

    func allIdentifiers(location: EncryptedAssetLocation) throws -> Set<String> {
        let directory = rootURL.appendingPathComponent(location.rawValue, isDirectory: true)
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        return Set(names.compactMap { name in
            guard !name.hasPrefix("."), name.hasSuffix(".qfe") else { return nil }
            let identifier = String(name.dropLast(4))
            return UUID(uuidString: identifier) == nil ? nil : identifier
        })
    }

    private func encryptedURL(identifier: String, location: EncryptedAssetLocation) throws -> URL {
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
