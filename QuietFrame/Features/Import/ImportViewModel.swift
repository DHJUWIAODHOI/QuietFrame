import Foundation
import Observation
import PhotosUI
import UIKit

struct ImportPreviewCandidate: Identifiable {
    let source: ImportSource
    let previewImage: UIImage?

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

    func prepare(items: [PhotosPickerItem]) {
        preparationTask?.cancel()
        preparationGeneration &+= 1
        let generation = preparationGeneration
        cleanupPreparedFiles()
        candidates = []
        summary = nil
        userMessage = nil
        isPreparing = true

        preparationTask = Task { [weak self] in
            guard let self else { return }
            var prepared: [ImportPreviewCandidate] = []
            var failedCount = 0
            var thumbnailFailureCount = 0

            for item in items {
                do {
                    try Task.checkCancellation()
                    guard let transfer = try await item.loadTransferable(type: PhotoPickerTransfer.self) else {
                        throw VaultError.importFailed
                    }
                    do {
                        guard generation == preparationGeneration, !Task.isCancelled else {
                            IncomingMediaFileStore.remove(transfer.url)
                            throw CancellationError()
                        }
                        let metadata = try await metadataReader.metadata(
                            for: transfer.url,
                            mediaType: transfer.mediaType,
                            originalFilename: transfer.originalFilename
                        )
                        guard generation == preparationGeneration, !Task.isCancelled else {
                            IncomingMediaFileStore.remove(transfer.url)
                            throw CancellationError()
                        }
                        let thumbnailData: Data?
                        do {
                            thumbnailData = try await thumbnailGenerator.jpegThumbnail(
                                for: transfer.url,
                                mediaType: transfer.mediaType,
                                maximumPixelSize: 720
                            )
                        } catch {
                            thumbnailData = nil
                            thumbnailFailureCount += 1
                        }
                        guard generation == preparationGeneration, !Task.isCancelled else {
                            IncomingMediaFileStore.remove(transfer.url)
                            throw CancellationError()
                        }
                        let source = ImportSource(
                            temporaryURL: transfer.url,
                            metadata: metadata,
                            thumbnailJPEGData: thumbnailData,
                            sourceLocalIdentifier: item.itemIdentifier
                        )
                        prepared.append(ImportPreviewCandidate(
                            source: source,
                            previewImage: thumbnailData.flatMap { UIImage(data: $0) }
                        ))
                    } catch {
                        IncomingMediaFileStore.remove(transfer.url)
                        throw error
                    }
                } catch is CancellationError {
                    prepared.forEach { IncomingMediaFileStore.remove($0.source.temporaryURL) }
                    if generation == preparationGeneration { isPreparing = false }
                    return
                } catch {
                    failedCount += 1
                }
            }

            guard generation == preparationGeneration else {
                prepared.forEach { IncomingMediaFileStore.remove($0.source.temporaryURL) }
                return
            }
            candidates = prepared
            isPreparing = false
            if failedCount > 0 || thumbnailFailureCount > 0 {
                var messages: [String] = []
                if failedCount > 0 {
                    messages.append("\(failedCount) item\(failedCount == 1 ? "" : "s") could not be prepared")
                }
                if thumbnailFailureCount > 0 {
                    messages.append("\(thumbnailFailureCount) preview\(thumbnailFailureCount == 1 ? "" : "s") could not be generated")
                }
                userMessage = messages.joined(separator: "; ") + "."
            }
            if prepared.isEmpty, failedCount > 0 {
                userMessage = VaultError.importFailed.localizedDescription
            }
        }
    }

    func removeCandidate(id: UUID) {
        guard !isImporting,
              let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        IncomingMediaFileStore.remove(candidates[index].source.temporaryURL)
        candidates.remove(at: index)
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
                let result = try await importer.importMedia(sources, albumID: albumID) { [weak self] value in
                    await MainActor.run { self?.progress = value }
                }
                summary = result
                candidates = []
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
        guard let identifiers = summary?.importedSourceLocalIdentifiers,
              !identifiers.isEmpty,
              !isDeletingOriginals else { return }
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
