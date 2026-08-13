import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppModel {
    enum BootstrapState {
        case loading
        case ready(AppDependencies)
        case failed(String)
    }

    private(set) var bootstrapState: BootstrapState = .loading
    private var didBootstrap = false

    func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            let schema = Schema(versionedSchema: VaultSchemaV3.self)
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            try await AppResetJournal.completePendingReset(storeURL: configuration.url)
            try protectMetadataStoreDirectory(configuration.url.deletingLastPathComponent())
            let container = try ModelContainer(
                for: schema,
                migrationPlan: VaultMigrationPlan.self,
                configurations: [configuration]
            )
            try protectMetadataStoreFiles(configuration.url)
            try Self.initializeAlbumPositions(in: container.mainContext)
            try createSettingsIfNeeded(in: container.mainContext)
            let dependencies = try AppDependencies(modelContainer: container)
            bootstrapState = .ready(dependencies)
        } catch {
            bootstrapState = .failed(VaultError.migrationFailed.localizedDescription)
        }
    }

    func retryBootstrap() async {
        didBootstrap = false
        bootstrapState = .loading
        await bootstrapIfNeeded()
    }

    private func createSettingsIfNeeded(in context: ModelContext) throws {
        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).isEmpty {
            context.insert(AppSettings())
            try context.save()
        }
    }

    static func initializeAlbumPositions(in context: ModelContext) throws {
        let albums = try context.fetch(FetchDescriptor<VaultAlbum>())
        guard Set(albums.map(\.position)).count != albums.count else { return }
        let ordered = albums.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
        for (position, album) in ordered.enumerated() {
            album.position = position
        }
        try context.save()
    }

    private func protectMetadataStoreDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
    }

    private func protectMetadataStoreFiles(_ storeURL: URL) throws {
        let candidates = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: candidate.path
            )
            var mutableURL = candidate
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
        }
    }
}
