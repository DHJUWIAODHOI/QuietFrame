import Foundation
import Observation
import UIKit

struct ImportPreviewCandidate: Identifiable {
    let source: ImportSource
    let previewImage: UIImage?
    let thumbnailFailed: Bool

    var id: UUID { source.id }
}

@MainActor
@Observable
final class ImportViewModel {
    private(set) var candidates: [ImportPreviewCandidate] = []
    private(set) var isPreparing = false
    /// Items of the current selection that have finished preparing, out of `preparationTotal`.
    private(set) var preparedCount = 0
    private(set) var preparationTotal = 0
    private(set) var isImporting = false
    private(set) var isDeletingOriginals = false
    private(set) var progress = ImportProgress(completedItems: 0, totalItems: 0, currentItemFraction: 0)
    private(set) var summary: ImportSummary?
    private(set) var albumAssignments = ImportAlbumAssignments()
    var userMessage: String?

    private let metadataReader: any MediaMetadataReading
    private let thumbnailGenerator: any ThumbnailGenerating
    private let importer: any MediaImporting
    private let photoLibrary: any PhotoLibraryServing
    private var preparationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var preparationGeneration: UInt64 = 0
    private var preparationFailureCount = 0
    private var preparationThumbnailFailureCount = 0

    /// Items prepared at once: enough to overlap copying, reading and preview work without holding many decodes.
    private static let preparationConcurrency = 3

    private enum PreparationOutcome: Sendable {
        case prepared(ImportSource, previewImage: UIImage?, thumbnailFailed: Bool)
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

        preparationTask = Task { [weak self] in
            let deletionUnavailableCount = selections.reduce(into: 0) { count, selection in
                if selection.sourceLocalIdentifier == nil { count += 1 }
            }
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

            var prepared: [ImportPreviewCandidate] = []
            var failedCount = pickerFailureCount
            var thumbnailFailureCount = 0
            var wasCancelled = false
            for outcome in outcomes {
                switch outcome {
                case .prepared(let source, let previewImage, let thumbnailFailed):
                    prepared.append(ImportPreviewCandidate(
                        source: source,
                        previewImage: previewImage,
                        thumbnailFailed: thumbnailFailed
                    ))
                    if thumbnailFailed { thumbnailFailureCount += 1 }
                case .failed:
                    failedCount += 1
                case .cancelled(let temporaryURL):
                    if let temporaryURL { IncomingMediaFileStore.remove(temporaryURL) }
                    wasCancelled = true
                case nil:
                    wasCancelled = true
                }
            }

            guard let self, generation == self.preparationGeneration, !wasCancelled, !Task.isCancelled else {
                prepared.forEach { IncomingMediaFileStore.remove($0.source.temporaryURL) }
                if let self, generation == self.preparationGeneration { self.isPreparing = false }
                return
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

    /// Copies, reads and previews one picked item off the main actor. Its incoming copy is removed when it fails.
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
            let thumbnailData = try? await thumbnailGenerator.jpegThumbnail(
                for: loadedFile.temporaryURL,
                mediaType: selection.mediaType,
                maximumPixelSize: ThumbnailService.storedPixelSize
            )
            try Task.checkCancellation()
            let source = ImportSource(
                temporaryURL: loadedFile.temporaryURL,
                metadata: metadata,
                thumbnailJPEGData: thumbnailData,
                sourceLocalIdentifier: selection.sourceLocalIdentifier
            )
            let previewImage = thumbnailData.flatMap {
                ThumbnailService.downsampledImage(from: $0, maximumPixelSize: ThumbnailService.storedPixelSize)
            }
            return .prepared(source, previewImage: previewImage, thumbnailFailed: thumbnailData == nil)
        } catch is CancellationError {
            return .cancelled(temporaryURL: temporaryURL)
        } catch {
            if let temporaryURL { IncomingMediaFileStore.remove(temporaryURL) }
            return .failed
        }
    }

    func removeCandidate(id: UUID) {
        guard !isImporting,
              let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        let candidate = candidates[index]
        IncomingMediaFileStore.remove(candidate.source.temporaryURL)
        candidates.remove(at: index)
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

    /// Encryption hands each progress value over without waiting for the main thread. While the main thread is busy,
    /// only the newest value waits to be shown.
    private func runImport(_ sources: [ImportSource], albumID: UUID?) async throws -> ImportSummary {
        let (updates, continuation) = AsyncStream.makeStream(
            of: ImportProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let showingProgress = Task {
            for await value in updates where value != progress {
                progress = value
            }
        }
        do {
            let summary = try await importer.importMedia(
                sources,
                albumID: albumID,
                preflightFailureCount: preparationFailureCount,
                preflightThumbnailFailureCount: preparationThumbnailFailureCount
            ) { value in
                continuation.yield(value)
            }
            continuation.finish()
            await showingProgress.value
            return summary
        } catch {
            continuation.finish()
            await showingProgress.value
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
        candidates.forEach { IncomingMediaFileStore.remove($0.source.temporaryURL) }
    }
}
