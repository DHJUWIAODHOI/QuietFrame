import AVKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct SecureMediaPage: View {
    let media: VaultMedia
    let isActive: Bool
    let shouldPrepare: Bool
    let storage: any SecureFileStoring
    let onPhotoTap: () -> Void
    let onPhotoZoomChanged: (Bool) -> Void
    let onVideoPlaybackChanged: (Bool) -> Void

    var body: some View {
        switch media.mediaType {
        case .photo:
            SecurePhotoPage(
                media: media,
                isActive: isActive,
                shouldPrepare: shouldPrepare,
                storage: storage,
                onTap: onPhotoTap,
                onZoomChanged: onPhotoZoomChanged
            )
        case .video:
            SecureVideoPage(
                media: media,
                isActive: isActive,
                shouldPrepare: shouldPrepare,
                storage: storage,
                onPlaybackChanged: onVideoPlaybackChanged
            )
        }
    }
}

private struct SecurePhotoPage: View {
    let media: VaultMedia
    let isActive: Bool
    let shouldPrepare: Bool
    let storage: any SecureFileStoring
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void

    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                if isActive {
                    ZoomablePhotoView(
                        image: image,
                        accessibilityLabel: media.accessibilitySummary,
                        onZoomChanged: onZoomChanged
                    )
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(media.accessibilitySummary)
                }
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
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { if isActive { onTap() } })
        .task(id: shouldPrepare) {
            if shouldPrepare {
                await loadWhenReady()
            } else {
                image = nil
                errorMessage = nil
            }
        }
    }

    private func loadWhenReady() async {
        while isLoading {
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        await load()
    }

    private func load() async {
        guard image == nil, !isLoading else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await storage.decryptData(
                identifier: media.storageIdentifier,
                location: media.isTrashed ? .trash : .media,
                maximumByteCount: 512 * 1_024 * 1_024
            )
            try Task.checkCancellation()
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
            guard !Task.isCancelled, shouldPrepare else { return }
            image = decoded
        } catch is CancellationError {
            return
        } catch VaultError.importCancelled {
            return
        } catch {
            guard !Task.isCancelled, shouldPrepare else { return }
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.corruptedFile.localizedDescription
        }
    }
}

private struct SecureVideoPage: View {
    let media: VaultMedia
    let isActive: Bool
    let shouldPrepare: Bool
    let storage: any SecureFileStoring
    let onPlaybackChanged: (Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase

    @State private var lease: SecureTemporaryFileLease?
    @State private var player: AVQueuePlayer?
    @State private var playerLooper: AVPlayerLooper?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var shouldPlayWhenReady = false
    @State private var playbackStatus: AVPlayer.TimeControlStatus = .paused

    var body: some View {
        ZStack {
            Color.black
            if let player {
                SecureVideoPlayerView(
                    player: player,
                    showsPlaybackControls: isActive,
                    onContentTap: startPlayback
                )
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                    .accessibilityLabel(media.accessibilitySummary)
                    .onReceive(player.publisher(
                        for: \.timeControlStatus,
                        options: [.initial, .new]
                    ).receive(on: RunLoop.main)) { status in
                        guard isActive else { return }
                        guard playbackStatus != status else { return }
                        playbackStatus = status
                        onPlaybackChanged(status != .paused)
                    }
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
        .overlay {
            if player == nil, errorMessage == nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: startPlayback)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                    .accessibilityLabel("Play video")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .task(id: playbackLifecycleID) {
            if !shouldPrepare {
                cleanup()
            } else if scenePhase == .active {
                await loadWhenReady()
            } else {
                pausePlayback()
            }
        }
        .onChange(of: isActive) { _, isActive in
            if !isActive { pausePlayback() }
        }
        .onDisappear { cleanup() }
    }

    private func loadWhenReady() async {
        while isLoading {
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        await load()
    }

    private func load() async {
        guard player == nil, !isLoading else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let fileExtension = UTType(media.contentTypeIdentifier)?.preferredFilenameExtension
            let newLease = try await storage.temporaryDecryptedFile(
                identifier: media.storageIdentifier,
                location: media.isTrashed ? .trash : .media,
                preferredExtension: fileExtension
            )
            guard !Task.isCancelled, shouldPrepare, scenePhase == .active else {
                newLease.cleanup()
                return
            }
            let newPlayer = AVQueuePlayer()
            let newLooper = AVPlayerLooper(
                player: newPlayer,
                templateItem: AVPlayerItem(url: newLease.url)
            )
            lease = newLease
            playerLooper = newLooper
            player = newPlayer
            if shouldPlayWhenReady {
                newPlayer.play()
            }
        } catch is CancellationError {
            return
        } catch VaultError.importCancelled {
            return
        } catch {
            guard !Task.isCancelled, shouldPrepare else { return }
            shouldPlayWhenReady = false
            playbackStatus = .paused
            onPlaybackChanged(false)
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.corruptedFile.localizedDescription
        }
    }

    private func startPlayback() {
        guard isActive else { return }
        shouldPlayWhenReady = true
        player?.play()
    }

    private func pausePlayback() {
        shouldPlayWhenReady = false
        player?.pause()
        playbackStatus = .paused
        onPlaybackChanged(false)
    }

    private var playbackLifecycleID: Int {
        guard shouldPrepare else { return 0 }
        switch scenePhase {
        case .active: return 1
        case .inactive: return 2
        case .background: return 3
        @unknown default: return 4
        }
    }

    private func cleanup() {
        pausePlayback()
        playerLooper?.disableLooping()
        playerLooper = nil
        player?.removeAllItems()
        player = nil
        lease?.cleanup()
        lease = nil
        errorMessage = nil
    }
}

private struct SecureVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let showsPlaybackControls: Bool
    let onContentTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onContentTap: onContentTap)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleContentTap)
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        controller.view.addGestureRecognizer(tapGesture)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        context.coordinator.onContentTap = onContentTap
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        controller.player = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onContentTap: () -> Void

        init(onContentTap: @escaping () -> Void) {
            self.onContentTap = onContentTap
        }

        @objc func handleContentTap() {
            onContentTap()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var view = touch.view
            while let currentView = view {
                if currentView is UIControl
                    || currentView.accessibilityTraits.contains(.button)
                    || currentView.accessibilityTraits.contains(.adjustable) {
                    return false
                }
                view = currentView.superview
            }
            return true
        }
    }
}
