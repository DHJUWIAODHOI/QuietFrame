import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct SecureMediaPage: View {
    let media: VaultMedia
    let isActive: Bool
    let storage: any SecureFileStoring

    var body: some View {
        switch media.mediaType {
        case .photo:
            SecurePhotoPage(media: media, isActive: isActive, storage: storage)
        case .video:
            SecureVideoPage(media: media, isActive: isActive, storage: storage)
        }
    }
}

private struct SecurePhotoPage: View {
    let media: VaultMedia
    let isActive: Bool
    let storage: any SecureFileStoring

    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomablePhotoView(image: image, accessibilityLabel: media.accessibilitySummary)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Photo Unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.white)
            } else if isLoading {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Decrypting photo")
            }
        }
        .task(id: isActive) {
            if isActive {
                await load()
            } else {
                image = nil
                errorMessage = nil
            }
        }
    }

    private func load() async {
        guard image == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await storage.decryptData(
                identifier: media.storageIdentifier,
                location: media.isTrashed ? .trash : .media,
                maximumByteCount: 512 * 1_024 * 1_024
            )
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 4_096,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary
                      ) else { return nil }
                return UIImage(cgImage: image)
            }.value
            guard let decoded else { throw VaultError.corruptedFile }
            guard !Task.isCancelled, isActive else { return }
            image = decoded
        } catch {
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.corruptedFile.localizedDescription
        }
    }
}

private struct SecureVideoPage: View {
    let media: VaultMedia
    let isActive: Bool
    let storage: any SecureFileStoring

    @State private var lease: SecureTemporaryFileLease?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel(media.accessibilitySummary)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Video Unavailable",
                    systemImage: "video.slash",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.white)
            } else if isLoading {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Preparing encrypted video")
            }
        }
        .task(id: isActive) {
            if isActive {
                await load()
            } else {
                cleanup()
            }
        }
        .onDisappear { cleanup() }
    }

    private func load() async {
        guard player == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fileExtension = UTType(media.contentTypeIdentifier)?.preferredFilenameExtension
            let newLease = try await storage.temporaryDecryptedFile(
                identifier: media.storageIdentifier,
                location: media.isTrashed ? .trash : .media,
                preferredExtension: fileExtension
            )
            guard !Task.isCancelled, isActive else {
                newLease.cleanup()
                return
            }
            lease = newLease
            player = AVPlayer(url: newLease.url)
        } catch {
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.corruptedFile.localizedDescription
        }
    }

    private func cleanup() {
        player?.pause()
        player = nil
        lease?.cleanup()
        lease = nil
        errorMessage = nil
    }
}
