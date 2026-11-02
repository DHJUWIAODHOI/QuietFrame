import Foundation
@testable import QuietFrame

/// Real encrypted storage in a fresh temporary directory, without file protection. Files placed with `place` stand
/// in for encrypted ones: moves, deletes and size checks never read what is inside.
struct TemporaryVaultStorage {
    let root: URL
    let storage: SecureFileStorageService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = try SecureFileStorageService(
            encryption: ChunkedEncryptionService(session: VaultSession()),
            baseURL: root.appendingPathComponent("storage", isDirectory: true),
            temporaryBaseURL: root.appendingPathComponent("cache", isDirectory: true),
            applyFileProtection: false
        )
    }

    func directory(for location: EncryptedAssetLocation) -> URL {
        root.appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("QuietFrameVault", isDirectory: true)
            .appendingPathComponent(location.rawValue, isDirectory: true)
    }

    func url(of identifier: String, in location: EncryptedAssetLocation) -> URL {
        directory(for: location).appendingPathComponent("\(identifier).qfe", isDirectory: false)
    }

    @discardableResult
    func place(
        _ identifier: String = UUID().uuidString.lowercased(),
        in location: EncryptedAssetLocation,
        byteCount: Int = 64
    ) throws -> String {
        try Data(repeating: 0x51, count: byteCount).write(to: url(of: identifier, in: location))
        return identifier
    }

    func contains(_ identifier: String, in location: EncryptedAssetLocation) -> Bool {
        FileManager.default.fileExists(atPath: url(of: identifier, in: location).path)
    }

    func fileNames(in location: EncryptedAssetLocation) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory(for: location).path))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
