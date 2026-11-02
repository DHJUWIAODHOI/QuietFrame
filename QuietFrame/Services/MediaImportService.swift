import Foundation

struct ImportSource: Identifiable, Sendable {
    let id: UUID
    let temporaryURL: URL
    let metadata: MediaMetadata
    let thumbnailJPEGData: Data?
    let sourceLocalIdentifier: String?
    /// The album this item is imported into; nil uses the import's default album.
    var albumID: UUID?

    init(
        id: UUID = UUID(),
        temporaryURL: URL,
        metadata: MediaMetadata,
        thumbnailJPEGData: Data?,
        sourceLocalIdentifier: String?,
        albumID: UUID? = nil
    ) {
        self.id = id
        self.temporaryURL = temporaryURL
        self.metadata = metadata
        self.thumbnailJPEGData = thumbnailJPEGData
        self.sourceLocalIdentifier = sourceLocalIdentifier
        self.albumID = albumID
    }
}

struct ImportProgress: Sendable, Equatable {
    let completedItems: Int
    let totalItems: Int
    let currentItemFraction: Double

    var overallFraction: Double {
        guard totalItems > 0 else { return 0 }
        return min(1, (Double(completedItems) + currentItemFraction) / Double(totalItems))
    }
}

struct ImportSummary: Sendable, Equatable {
    var importedCount = 0
    var duplicateCount = 0
    var failedCount = 0
    var thumbnailFailureCount = 0
    var wasCancelled = false
    var importedMediaIDs: [UUID] = []
    var importedSourceLocalIdentifiers: [String] = []

    var shouldOfferOriginalDeletion: Bool {
        importedCount > 0 && canDeleteImportedOriginals
    }

    var canDeleteImportedOriginals: Bool {
        importedSourceLocalIdentifiers.count == importedCount
    }
}

protocol MediaImporting: Sendable {
    func importMedia(
        _ sources: [ImportSource],
        albumID: UUID?,
        preflightFailureCount: Int,
        preflightThumbnailFailureCount: Int,
        progress: (@Sendable (ImportProgress) async -> Void)?
    ) async throws -> ImportSummary
    func cleanupAbandonedIncomingFiles() async
    func cancelAllOperations() async
}

actor MediaImportService: MediaImporting {
    private let storage: any SecureFileStoring
    private let repository: any VaultRepositoryProtocol
    private let operationGate: VaultOperationGate
    private var operationGeneration: UInt64 = 0

    init(
        storage: any SecureFileStoring,
        repository: any VaultRepositoryProtocol,
        operationGate: VaultOperationGate = VaultOperationGate()
    ) {
        self.storage = storage
        self.repository = repository
        self.operationGate = operationGate
    }

    func importMedia(
        _ sources: [ImportSource],
        albumID: UUID? = nil,
        preflightFailureCount: Int = 0,
        preflightThumbnailFailureCount: Int = 0,
        progress: (@Sendable (ImportProgress) async -> Void)? = nil
    ) async throws -> ImportSummary {
        let generation = operationGeneration
        return try await operationGate.withLock {
            guard !sources.isEmpty else { throw VaultError.invalidInput("Choose at least one item to import.") }
            let initialFailureCount = max(0, preflightFailureCount)
            let requestedCount = sources.count + initialFailureCount
            let recordID = try await repository.beginImport(requestedCount: requestedCount)
            var summary = ImportSummary()
            summary.failedCount = initialFailureCount
            summary.thumbnailFailureCount = max(0, preflightThumbnailFailureCount)
            defer { sources.forEach { IncomingMediaFileStore.remove($0.temporaryURL) } }

            for (index, source) in sources.enumerated() {
                defer { IncomingMediaFileStore.remove(source.temporaryURL) }
                do {
                    try Task.checkCancellation()
                    guard generation == operationGeneration else { throw CancellationError() }
                    try ensureAvailableStorage(for: source.metadata.byteCount, at: source.temporaryURL)
                    await progress?(ImportProgress(
                        completedItems: index,
                        totalItems: sources.count,
                        currentItemFraction: 0
                    ))

                    let storedMedia = try await storage.store(
                        plaintextURL: source.temporaryURL,
                        location: .media
                    ) { fraction in
                        await progress?(ImportProgress(
                            completedItems: index,
                            totalItems: sources.count,
                            currentItemFraction: fraction * 0.9
                        ))
                    }

                    if try await repository.containsFingerprint(storedMedia.result.fingerprint) {
                        try await storage.delete(identifier: storedMedia.identifier, location: .media)
                        summary.duplicateCount += 1
                        continue
                    }

                    guard generation == operationGeneration else {
                        try? await storage.delete(identifier: storedMedia.identifier, location: .media)
                        throw CancellationError()
                    }

                    var thumbnailIdentifier: String?
                    if let thumbnailData = source.thumbnailJPEGData {
                        do {
                            thumbnailIdentifier = try await storage.store(
                                plaintextData: thumbnailData,
                                location: .thumbnails
                            ).identifier
                        } catch is CancellationError {
                            try? await storage.delete(identifier: storedMedia.identifier, location: .media)
                            throw CancellationError()
                        } catch VaultError.importCancelled {
                            try? await storage.delete(identifier: storedMedia.identifier, location: .media)
                            throw VaultError.importCancelled
                        } catch VaultError.authenticationRequired {
                            try? await storage.delete(identifier: storedMedia.identifier, location: .media)
                            throw VaultError.authenticationRequired
                        } catch {
                            summary.thumbnailFailureCount += 1
                        }
                    }

                    do {
                        guard generation == operationGeneration else {
                            try? await storage.delete(identifier: storedMedia.identifier, location: .media)
                            if let thumbnailIdentifier {
                                try? await storage.delete(identifier: thumbnailIdentifier, location: .thumbnails)
                            }
                            throw CancellationError()
                        }
                        let mediaID = try await repository.insertImportedMedia(
                            storageIdentifier: storedMedia.identifier,
                            thumbnailIdentifier: thumbnailIdentifier,
                            fingerprint: storedMedia.result.fingerprint,
                            metadata: source.metadata,
                            albumID: source.albumID ?? albumID
                        )
                        guard generation == operationGeneration else {
                            try await repository.deleteImportedMedia(id: mediaID)
                            throw CancellationError()
                        }
                        summary.importedCount += 1
                        summary.importedMediaIDs.append(mediaID)
                        if let identifier = source.sourceLocalIdentifier {
                            summary.importedSourceLocalIdentifiers.append(identifier)
                        }
                    } catch {
                        try? await storage.delete(identifier: storedMedia.identifier, location: .media)
                        if let thumbnailIdentifier {
                            try? await storage.delete(identifier: thumbnailIdentifier, location: .thumbnails)
                        }
                        throw error
                    }
                } catch is CancellationError {
                    summary.wasCancelled = true
                    break
                } catch VaultError.importCancelled {
                    summary.wasCancelled = true
                    break
                } catch VaultError.authenticationRequired {
                    summary.wasCancelled = true
                    break
                } catch {
                    summary.failedCount += 1
                }

                await progress?(ImportProgress(
                    completedItems: index + 1,
                    totalItems: sources.count,
                    currentItemFraction: 0
                ))
            }

            let status: ImportStatus
            if summary.wasCancelled {
                status = .cancelled
            } else if summary.failedCount == requestedCount {
                status = .failed
            } else {
                status = .completed
            }
            try await repository.finishImport(id: recordID, summary: summary, status: status)
            return summary
        }
    }

    func cleanupAbandonedIncomingFiles() {
        IncomingMediaFileStore.removeAll()
    }

    func cancelAllOperations() {
        operationGeneration &+= 1
        IncomingMediaFileStore.removeAll()
    }

    private func ensureAvailableStorage(for byteCount: Int64, at url: URL) throws {
        guard byteCount > 0 else { throw VaultError.unsupportedFileType }
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let safetyMargin: Int64 = 32 * 1_024 * 1_024
        guard available > byteCount + safetyMargin else { throw VaultError.insufficientStorage }
    }
}
