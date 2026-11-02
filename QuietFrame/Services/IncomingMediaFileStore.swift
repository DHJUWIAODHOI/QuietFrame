import Foundation

enum IncomingMediaFileStore {
    static func copyProtectedFile(from sourceURL: URL) throws -> URL {
        let directory = try incomingDirectory()
        let fileExtension = sanitizedExtension(sourceURL.pathExtension)
        let suffix = fileExtension.map { ".\($0)" } ?? ""
        let destination = directory.appendingPathComponent(UUID().uuidString.lowercased() + suffix)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        do {
            try protectAndExclude(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func remove(_ url: URL) {
        guard isIncomingURL(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes incoming copies on a utility queue, so the caller, usually the main thread, never waits for the unlinks.
    static func removeInBackground(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in urls {
                IncomingMediaFileStore.remove(url)
            }
        }
    }

    static func removeAll() {
        guard let directory = try? incomingDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }
        files.forEach(remove)
    }

    private static func incomingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuietFrameIncoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
        return directory
    }

    private static func protectAndExclude(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func isIncomingURL(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "QuietFrameIncoming"
    }

    private static func sanitizedExtension(_ candidate: String) -> String? {
        let value = candidate.lowercased().filter { character in
            (character >= "a" && character <= "z") || (character >= "0" && character <= "9")
        }
        guard !value.isEmpty else { return nil }
        return String(value.prefix(8))
    }
}
