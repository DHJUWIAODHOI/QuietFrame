import SwiftData

enum VaultSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self]
    }
}

enum VaultMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [VaultSchemaV1.self]
    }

    static var stages: [MigrationStage] { [] }
}
