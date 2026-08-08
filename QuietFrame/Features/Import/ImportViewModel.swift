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
    private(set) var isImporting = false
    private(set) var isDeletingOriginals = false
    private(set) var progress = ImportProgress(completedItems: 0, totalItems: 0, currentItemFraction: 0)
    private(set) var summary: ImportSummary?
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
        summary = nil
        userMessage = nil
        isPreparing = true
        preparationFailureCount = 0
        preparationThumbnailFailureCount = 0

        preparationTask = Task { [weak self] in
            guard let self else { return }
            var prepared: [ImportPreviewCandidate] = []
            let deletionUnavailableCount = selections.reduce(into: 0) { count, selection in
                if selection.sourceLocalIdentifier == nil { count += 1 }
            }
            var failedCount = pickerFailureCount
            var thumbnailFailureCount = 0

            for selection in selections {
                var temporaryURL: URL?
                do {
                    try Task.checkCancellation()
                    let loadedFile = try await selection.loadProtectedFile()
                    temporaryURL = loadedFile.temporaryURL
                    guard generation == preparationGeneration, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    let metadata = try await metadataReader.metadata(
                        for: loadedFile.temporaryURL,
                        mediaType: selection.mediaType,
                        originalFilename: loadedFile.originalFilename
                    )
                    guard generation == preparationGeneration, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    let thumbnailData: Data?
                    let thumbnailFailed: Bool
                    do {
                        thumbnailData = try await thumbnailGenerator.jpegThumbnail(
                            for: loadedFile.temporaryURL,
                            mediaType: selection.mediaType,
                            maximumPixelSize: 720
                        )
                        thumbnailFailed = false
                    } catch {
                        thumbnailData = nil
                        thumbnailFailed = true
                        thumbnailFailureCount += 1
                    }
                    guard generation == preparationGeneration, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    let source = ImportSource(
                        temporaryURL: loadedFile.temporaryURL,
                        metadata: metadata,
                        thumbnailJPEGData: thumbnailData,
                        sourceLocalIdentifier: selection.sourceLocalIdentifier
                    )
                    prepared.append(ImportPreviewCandidate(
                        source: source,
                        previewImage: thumbnailData.flatMap { UIImage(data: $0) },
                        thumbnailFailed: thumbnailFailed
                    ))
                    temporaryURL = nil
                } catch is CancellationError {
                    if let temporaryURL { IncomingMediaFileStore.remove(temporaryURL) }
                    prepared.forEach { IncomingMediaFileStore.remove($0.source.temporaryURL) }
                    if generation == preparationGeneration { isPreparing = false }
                    return
                } catch {
                    if let temporaryURL { IncomingMediaFileStore.remove(temporaryURL) }
                    failedCount += 1
                }
            }

            guard generation == preparationGeneration else {
                prepared.forEach { IncomingMediaFileStore.remove($0.source.temporaryURL) }
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

    func removeCandidate(id: UUID) {
        guard !isImporting,
              let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        let candidate = candidates[index]
        IncomingMediaFileStore.remove(candidate.source.temporaryURL)
        candidates.remove(at: index)
        if candidate.thumbnailFailed {
            preparationThumbnailFailureCount = max(0, preparationThumbnailFailureCount - 1)
        }
    }

    func startImport(albumID: UUID? = nil) {
        guard !candidates.isEmpty, !isImporting else { return }
        isImporting = true
        summary = nil
        userMessage = nil
        let sources = candidates.map(\.source)
        progress = ImportProgress(completedItems: 0, totalItems: sources.count, currentItemFraction: 0)

        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await importer.importMedia(
                    sources,
                    albumID: albumID,
                    preflightFailureCount: preparationFailureCount,
                    preflightThumbnailFailureCount: preparationThumbnailFailureCount
                ) { [weak self] value in
                    await MainActor.run { self?.progress = value }
                }
                summary = result
                candidates = []
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

    func cancelPreparation() {
        preparationTask?.cancel()
        preparationGeneration &+= 1
        cleanupPreparedFiles()
        candidates = []
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
    }

    private func cleanupPreparedFiles() {
        candidates.forEach { IncomingMediaFileStore.remove($0.source.temporaryURL) }
    }
}
