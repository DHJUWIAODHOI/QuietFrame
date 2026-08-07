import Foundation

enum AppResetJournal {
    private static let markerFilename = "reset-in-progress"

    static func isPending() throws -> Bool {
        FileManager.default.fileExists(atPath: try markerURL().path)
    }

    static func begin() throws {
        let url = try markerURL()
        try Data("QuietFrame reset v1".utf8).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    static func finish() throws {
        let url = try markerURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func completePendingReset(storeURL: URL) async throws {
        guard try isPending() else { return }

        let session = VaultSession()
        let authentication = AuthenticationService(
            keychain: KeychainService(),
            session: session
        )
        try await authentication.resetCredentials()

        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let paths = [
            applicationSupport.appendingPathComponent("QuietFrameVault", isDirectory: true),
            caches.appendingPathComponent("QuietFrameTemporary", isDirectory: true),
            fileManager.temporaryDirectory.appendingPathComponent("QuietFrameIncoming", isDirectory: true)
        ]
        for url in paths where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let storeDirectory = storeURL.deletingLastPathComponent()
        let storePrefix = storeURL.lastPathComponent
        let storeFiles = try fileManager.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in storeFiles where url.lastPathComponent.hasPrefix(storePrefix) {
            try fileManager.removeItem(at: url)
        }
        try finish()
    }

    private static func markerURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
        return directory.appendingPathComponent(markerFilename)
    }
}
