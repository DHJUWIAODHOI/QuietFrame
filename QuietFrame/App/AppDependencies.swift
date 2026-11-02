import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppDependencies {
    let modelContainer: ModelContainer
    let session: VaultSession
    let authentication: AuthenticationService
    let encryption: ChunkedEncryptionService
    let secureStorage: SecureFileStorageService
    let repository: VaultRepository
    let albumService: AlbumService
    let metadataService: MediaMetadataService
    let thumbnailGenerator: ThumbnailGenerator
    let thumbnailService: ThumbnailService
    let mediaImportService: MediaImportService
    let photoLibraryService: PhotoLibraryService
    let trashService: TrashService
    let mediaExportService: MediaExportService
    let storageAnalysisService: StorageAnalysisService
    let storageReconciliationService: StorageReconciliationService
    let lockCoordinator: VaultLockCoordinator

    init(modelContainer: ModelContainer) throws {
        self.modelContainer = modelContainer

        let session = VaultSession()
        let authentication = AuthenticationService(
            keychain: KeychainService(),
            session: session
        )
        let encryption = ChunkedEncryptionService(session: session)
        let secureStorage = try SecureFileStorageService(encryption: encryption)
        let operationGate = VaultOperationGate()
        let libraryChanges = LibraryChangeCounter()
        let repository = VaultRepository(modelContext: modelContainer.mainContext, changes: libraryChanges)
        let albumService = AlbumService(
            repository: repository,
            modelContext: modelContainer.mainContext,
            storage: secureStorage,
            operationGate: operationGate
        )
        let metadataService = MediaMetadataService()
        let thumbnailGenerator = ThumbnailGenerator()
        let thumbnailService = ThumbnailService(storage: secureStorage)
        let mediaImportService = MediaImportService(
            storage: secureStorage,
            repository: repository,
            operationGate: operationGate
        )
        let photoLibraryService = PhotoLibraryService()
        let trashService = TrashService(
            modelContext: modelContainer.mainContext,
            storage: secureStorage,
            operationGate: operationGate,
            changes: libraryChanges
        )
        let mediaExportService = MediaExportService(
            storage: secureStorage,
            repository: repository,
            operationGate: operationGate
        )
        let storageAnalysisService = StorageAnalysisService(
            modelContext: modelContainer.mainContext,
            storage: secureStorage
        )
        let storageReconciliationService = StorageReconciliationService(
            modelContext: modelContainer.mainContext,
            storage: secureStorage,
            operationGate: operationGate
        )

        self.session = session
        self.authentication = authentication
        self.encryption = encryption
        self.secureStorage = secureStorage
        self.repository = repository
        self.albumService = albumService
        self.metadataService = metadataService
        self.thumbnailGenerator = thumbnailGenerator
        self.thumbnailService = thumbnailService
        self.mediaImportService = mediaImportService
        self.photoLibraryService = photoLibraryService
        self.trashService = trashService
        self.mediaExportService = mediaExportService
        self.storageAnalysisService = storageAnalysisService
        self.storageReconciliationService = storageReconciliationService
        self.lockCoordinator = VaultLockCoordinator(
            authentication: authentication,
            secureStorage: secureStorage,
            modelContext: modelContainer.mainContext,
            operationGate: operationGate,
            cancelMediaOperations: {
                await mediaImportService.cancelAllOperations()
            },
            postUnlockMaintenance: {
                _ = try await storageReconciliationService.reconcile()
                _ = try await trashService.purgeExpiredItems()
            }
        )
    }
}
