import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoLibrarySelection {
    let itemProvider: NSItemProvider
    let typeIdentifier: String
    let mediaType: MediaType
    let originalFilename: String?
    let sourceLocalIdentifier: String?

    func loadProtectedFile() async throws -> PhotoLibraryLoadedFile {
        let transferState = ProviderTransferState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let progress = itemProvider.loadFileRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { url, error in
                    if transferState.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: VaultError.importFailed)
                        return
                    }
                    do {
                        let temporaryURL = try IncomingMediaFileStore.copyProtectedFile(from: url)
                        guard !transferState.isCancelled else {
                            IncomingMediaFileStore.remove(temporaryURL)
                            throw CancellationError()
                        }
                        let fallbackName = url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
                        continuation.resume(returning: PhotoLibraryLoadedFile(
                            temporaryURL: temporaryURL,
                            originalFilename: originalFilename ?? fallbackName
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                transferState.register(progress)
            }
        }, onCancel: {
            transferState.cancel()
        })
    }
}

struct PhotoLibraryLoadedFile {
    let temporaryURL: URL
    let originalFilename: String?
}

struct PhotoLibraryPickerOutput {
    let selections: [PhotoLibrarySelection]
    let pickerFailureCount: Int
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let allowsOriginalDeletion: Bool
    let completion: (PhotoLibraryPickerOutput) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            allowsOriginalDeletion: allowsOriginalDeletion,
            completion: completion
        )
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 250
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let allowsOriginalDeletion: Bool
        private let completion: (PhotoLibraryPickerOutput) -> Void

        init(
            allowsOriginalDeletion: Bool,
            completion: @escaping (PhotoLibraryPickerOutput) -> Void
        ) {
            self.allowsOriginalDeletion = allowsOriginalDeletion
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            var selections: [PhotoLibrarySelection] = []
            var pickerFailureCount = 0
            for result in results {
                let provider = result.itemProvider
                let mediaType: MediaType
                let typeIdentifier: String
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    mediaType = .photo
                    typeIdentifier = UTType.image.identifier
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    mediaType = .video
                    typeIdentifier = UTType.movie.identifier
                } else {
                    pickerFailureCount += 1
                    continue
                }
                selections.append(PhotoLibrarySelection(
                    itemProvider: provider,
                    typeIdentifier: typeIdentifier,
                    mediaType: mediaType,
                    originalFilename: provider.suggestedName,
                    sourceLocalIdentifier: Self.deletionIdentifier(
                        for: result,
                        allowsOriginalDeletion: allowsOriginalDeletion
                    )
                ))
            }
            completion(PhotoLibraryPickerOutput(
                selections: selections,
                pickerFailureCount: pickerFailureCount
            ))
        }

        private static func deletionIdentifier(
            for result: PHPickerResult,
            allowsOriginalDeletion: Bool
        ) -> String? {
            guard allowsOriginalDeletion else { return nil }
            let identifier = result.assetIdentifier
            let provider = result.itemProvider
            let providerHasLivePhoto = provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
            var asset: PHAsset?
            if let identifier, !identifier.isEmpty, !providerHasLivePhoto {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                if assets.count == 1 {
                    asset = assets.object(at: 0)
                }
            }
            return PhotoLibraryService.eligibleSourceIdentifier(
                identifier,
                allowsInspection: allowsOriginalDeletion,
                assetIsAccessible: asset != nil,
                providerHasLivePhoto: providerHasLivePhoto,
                resourceProfileIsSafe: asset.map(PhotoLibraryService.isSafeToDeleteAfterRepresentationImport) ?? false
            )
        }
    }
}

private final class ProviderTransferState: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ progress: Progress) {
        lock.lock()
        if cancelled {
            lock.unlock()
            progress.cancel()
            return
        }
        self.progress = progress
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let progress = progress
        lock.unlock()
        progress?.cancel()
    }
}
