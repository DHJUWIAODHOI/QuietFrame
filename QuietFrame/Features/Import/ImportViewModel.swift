import Foundation
import Observation
import UIKit

struct ImportPreviewCandidate: Identifiable {
    let source: ImportSource
    let thumbnailFailed: Bool

    var id: UUID { source.id }
}

@MainActor
@Observable
final class ImportViewModel {
    private(set) var candidates: [ImportPreviewCandidate] = []
    private(set) var isPreparing = false
    private(set) var preparedCount = 0
    private(set) var preparationTotal = 0
    private(set) var isImporting = false
    private(set) var isDeletingOriginals = false
    private(set) var progress = ImportProgress(completedItems: 0, totalItems: 0, currentItemFraction: 0)
    private(set) var summary: ImportSummary?
    private(set) var albumAssignments = ImportAlbumAssignments()
    var userMessage: String?
    let previewImages: ImportPreviewImages
    @ObservationIgnored var previewLayout: ImportPreviewLayout?

    private let metadataReader: any MediaMetadataReading
    private let thumbnailGenerator: any ThumbnailGenerating
    private let importer: any MediaImporting
    private let photoLibrary: any PhotoLibraryServing
    private var preparationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var preparationGeneration: UInt64 = 0
    private var preparationFailureCount = 0
    private var preparationThumbnailFailureCount = 0

    /// Enough to overlap copying, reading and preview work without holding many decodes.
    private static let preparationConcurrency = 3

    private enum PreparationOutcome: Sendable {
        case prepared(ImportPreparedFile)
        case failed
        case cancelled(temporaryURL: URL?)
    }

    init(
        metadataReader: any MediaMetadataReading,
        thumbnailGenerator: any ThumbnailGenerating,
        importer: any MediaImporting,
        photoLibrary: any PhotoLibraryServing
    ) {
        self.metadataReader = metadataReader
        self.thumbnailGenerator = thumbnailGenerator
        self.importer = importer
        self.photoLibrary = photoLibrary
        previewImages = ImportPreviewImages()
    }

    func prepare(
        selections: [PhotoLibrarySelection],
        pickerFailureCount: Int = 0
    ) {
        preparationTask?.cancel()
        preparationGeneration &+= 1
        let generation = preparationGeneration
        cleanupPreparedFiles()
        candidates = []
        albumAssignments.reset()
        summary = nil
        userMessage = nil
        isPreparing = true
        preparedCount = 0
        preparationTotal = selections.count
        preparationFailureCount = 0
        preparationThumbnailFailureCount = 0
        let metadataReader = metadataReader
        let thumbnailGenerator = thumbnailGenerator
        let photoLibrary = photoLibrary
        let deletionChecks = selections.map(\.deletionCheck)

        preparationTask = Task { [weak self] in
            async let resolvedSourceIdentifiers = ImportViewModel.resolveSourceIdentifiers(
                for: deletionChecks,
                photoLibrary: photoLibrary
            )
            var outcomes = [PreparationOutcome?](repeating: nil, count: selections.count)

            await withTaskGroup(of: (Int, PreparationOutcome).self) { group in
                var nextIndex = 0
                while nextIndex < min(ImportViewModel.preparationConcurrency, selections.count) {
                    let index = nextIndex
                    group.addTask {
                        (index, await ImportViewModel.prepare(selections[index], metadataReader: metadataReader, thumbnailGenerator: thumbnailGenerator))
                    }
                    nextIndex += 1
                }
                while let (index, outcome) = await group.next() {
                    outcomes[index] = outcome
                    if let self, generation == self.preparationGeneration {
                        self.preparedCount += 1
                    }
                    guard nextIndex < selections.count, !Task.isCancelled else { continue }
                    let next = nextIndex
                    group.addTask {
                        (next, await ImportViewModel.prepare(selections[next], metadataReader: metadataReader, thumbnailGenerator: thumbnailGenerator))
                    }
                    nextIndex += 1
                }
            }

            let sourceIdentifiers = await resolvedSourceIdentifiers
            let deletionUnavailableCount = sourceIdentifiers.filter { $0 == nil }.count
            var prepared: [ImportPreviewCandidate] = []
            var abandonedURLs: [URL] = []
            var failedCount = pickerFailureCount
            var thumbnailFailureCount = 0
            var wasCancelled = false
            for (index, outcome) in outcomes.enumerated() {
                switch outcome {
                case .prepared(let file):
                    let thumbnailFailed = file.thumbnailJPEGData == nil
                    prepared.append(ImportPreviewCandidate(
                        source: ImportSource(
                            temporaryURL: file.temporaryURL,
                            metadata: file.metadata,
                            thumbnailJPEGData: file.thumbnailJPEGData,
                            sourceLocalIdentifier: sourceIdentifiers[index]
                        ),
                        thumbnailFailed: thumbnailFailed
                    ))
                    if thumbnailFailed { thumbnailFailureCount += 1 }
                case .failed:
                    failedCount += 1
                case .cancelled(let temporaryURL):
                    if let temporaryURL { abandonedURLs.append(temporaryURL) }
                    wasCancelled = true
                case nil:
                    wasCancelled = true
                }
            }
            IncomingMediaFileStore.removeInBackground(abandonedURLs)

            guard let self, generation == self.preparationGeneration, !wasCancelled, !Task.isCancelled else {
                IncomingMediaFileStore.removeInBackground(prepared.map(\.source.temporaryURL))
                if let self, generation == self.preparationGeneration { self.isPreparing = false }
                return
            }
            if let layout = previewLayout {
                await previewImages.load(
                    Array(prepared.prefix(max(0, layout.firstScreenCount))),
                    tileWidth: layout.tileWidth,
                    scale: layout.scale
                )
                guard generation == preparationGeneration, !Task.isCancelled else {
                    IncomingMediaFileStore.removeInBackground(prepared.map(\.source.temporaryURL))
                    if generation == preparationGeneration { isPreparing = false }
                    return
                }
            }
            candidates = prepared
            preparationFailureCount = failedCount
            preparationThumbnailFailureCount = thumbnailFailureCount
            isPreparing = false
            if deletionUnavailableCount > 0 || failedCount > 0 || thumbnailFailureCount > 0 {
                var messages: [String] = []
                if deletionUnavailableCount > 0 {
                    messages.append("automatic deletion is unavailable for \(deletionUnavailableCount) item\(deletionUnavailableCount == 1 ? "" : "s") in this selection")
                }
                if failedCount > 0 {
                    messages.append("\(failedCount) item\(failedCount == 1 ? "" : "s") could not be prepared")
                }
                if thumbnailFailureCount > 0 {
                    messages.append("\(thumbnailFailureCount) preview\(thumbnailFailureCount == 1 ? "" : "s") could not be generated")
                }
                userMessage = messages.joined(separator: "; ") + "."
            }
        }
    }

    private nonisolated static func prepare(
        _ selection: PhotoLibrarySelection,
        metadataReader: any MediaMetadataReading,
        thumbnailGenerator: any ThumbnailGenerating
    ) async -> PreparationOutcome {
        var temporaryURL: URL?
        do {
            try Task.checkCancellation()
            let loadedFile = try await selection.loadProtectedFile()
            temporaryURL = loadedFile.temporaryURL
            try Task.checkCancellation()
            let metadata = try await metadataReader.metadata(
                for: loadedFile.temporaryURL,
                mediaType: selection.mediaType,
                originalFilename: loadedFile.originalFilename
            )
            try Task.checkCancellation()
            let thumbnailData: Data?
            do {
                thumbnailData = try await thumbnailGenerator.jpegThumbnail(
                    for: loadedFile.temporaryURL,
                    mediaType: selection.mediaType,
                    maximumPixelSize: ThumbnailService.storedPixelSize
                )
            } catch {
                thumbnailData = nil
            }
            try Task.checkCancellation()
            return .prepared(ImportPreparedFile(
                temporaryURL: loadedFile.temporaryURL,
                metadata: metadata,
                thumbnailJPEGData: thumbnailData
            ))
        } catch is CancellationError {
            return .cancelled(temporaryURL: temporaryURL)
        } catch {
            if let temporaryURL { IncomingMediaFileStore.remove(temporaryURL) }
            return .failed
        }
    }

    /// One identifier or nil per selection, in order; a short answer from PhotoKit can only withhold deletion.
    private nonisolated static func resolveSourceIdentifiers(
        for checks: [PhotoLibraryDeletionCheck],
        photoLibrary: any PhotoLibraryServing
    ) async -> [String?] {
        guard checks.contains(where: { $0.needsPhotoLibrary }) else {
            return checks.map { check -> String? in
                guard case .resolved(let identifier) = check else { return nil }
                return identifier
            }
        }
        let answers = await photoLibrary.sourceIdentifiers(for: checks)
        return checks.indices.map { index -> String? in
            answers.indices.contains(index) ? answers[index] : nil
        }
    }

    func removeCandidate(id: UUID) {
        guard !isImporting,
              let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        let candidate = candidates[index]
        IncomingMediaFileStore.removeInBackground([candidate.source.temporaryURL])
        candidates.remove(at: index)
        previewImages.remove(candidate.id)
        albumAssignments.remove(candidate.id)
        if candidate.thumbnailFailed {
            preparationThumbnailFailureCount = max(0, preparationThumbnailFailureCount - 1)
        }
    }

    func toggleSelection(id: UUID) {
        guard !isImporting, candidates.contains(where: { $0.id == id }) else { return }
        albumAssignments.toggleSelection(id)
    }

    func selectAllCandidates() {
        guard !isImporting else { return }
        albumAssignments.select(candidates.map(\.id))
    }

    func clearSelection() {
        albumAssignments.clearSelection()
    }

    /// Puts the selected items in `albumID`; nil sends them back to the default destination.
    func assignSelection(toAlbumID albumID: UUID?) {
        guard !isImporting else { return }
        albumAssignments.assignSelection(to: albumID)
    }

    func discardAlbumAssignments(notIn existingAlbumIDs: Set<UUID>) {
        albumAssignments.discardAlbums(notIn: existingAlbumIDs)
    }

    /// Starts encrypting every candidate. Items assigned to an album go there; the rest go to `albumID`.
    func startImport(albumID: UUID? = nil) {
        guard !candidates.isEmpty, !isImporting else { return }
        isImporting = true
        summary = nil
        userMessage = nil
        albumAssignments.clearSelection()
        let assignments = albumAssignments
        let sources = candidates.map { candidate in
            var source = candidate.source
            source.albumID = assignments.destination(for: candidate.id, defaultAlbumID: albumID)
            return source
        }
        progress = ImportProgress(completedItems: 0, totalItems: sources.count, currentItemFraction: 0)

        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runImport(sources, albumID: albumID)
                summary = result
                candidates = []
                previewImages.removeAll()
                albumAssignments.reset()
                if result.importedCount > 0, !result.canDeleteImportedOriginals {
                    userMessage = "Automatic deletion was not offered because every imported item could not be matched safely to a replaceable Photos asset."
                }
                if result.importedCount > 0 { HapticFeedback.success() }
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.importFailed.localizedDescription
            }
            isImporting = false
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    /// The last progress value is shown before the summary.
    private func runImport(_ sources: [ImportSource], albumID: UUID?) async throws -> ImportSummary {
        let progressRelay = LatestValueRelay<ImportProgress> { [weak self] value in
            guard let self, value != self.progress else { return }
            self.progress = value
        }
        do {
            let summary = try await importer.importMedia(
                sources,
                albumID: albumID,
                preflightFailureCount: preparationFailureCount,
                preflightThumbnailFailureCount: preparationThumbnailFailureCount
            ) { value in
                progressRelay.send(value)
            }
            await progressRelay.finish()
            return summary
        } catch {
            await progressRelay.finish()
            throw error
        }
    }

    func cancelPreparation() {
        preparationTask?.cancel()
        preparationGeneration &+= 1
        cleanupPreparedFiles()
        candidates = []
        albumAssignments.reset()
        isPreparing = false
    }

    func deleteImportedOriginals() {
        guard let summary, !isDeletingOriginals else { return }
        guard summary.canDeleteImportedOriginals else {
            userMessage = "iOS did not provide a safe reference for every imported original. QuietFrame did not delete anything; remove those items manually in Photos."
            return
        }
        let identifiers = summary.importedSourceLocalIdentifiers
        isDeletingOriginals = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await photoLibrary.deleteOriginals(localIdentifiers: identifiers)
                userMessage = "The selected originals were moved to Recently Deleted in Photos."
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
            }
            isDeletingOriginals = false
        }
    }

    func cleanupIfIdle() {
        guard !isImporting else { return }
        preparationTask?.cancel()
        preparationGeneration &+= 1
        cleanupPreparedFiles()
        candidates = []
        albumAssignments.reset()
    }

    private func cleanupPreparedFiles() {
        IncomingMediaFileStore.removeInBackground(candidates.map(\.source.temporaryURL))
        previewImages.removeAll()
    }
}

private struct ImportPreparedFile: Sendable {
    let temporaryURL: URL
    let metadata: MediaMetadata
    let thumbnailJPEGData: Data?
}
