import AVFoundation
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum VideoPageAction: Equatable {
    case cleanup
    case pause
    case load
    case idle
}

/// Videos are decrypted only for the selected page; prepared neighbours keep an existing player but never start one.
func videoPageAction(shouldPrepare: Bool, isActive: Bool, scenePhase: ScenePhase) -> VideoPageAction {
    guard shouldPrepare else { return .cleanup }
    guard scenePhase == .active else { return .pause }
    return isActive ? .load : .idle
}

struct SecureMediaPage: View {
    let media: VaultMedia
    let isActive: Bool
    let shouldPrepare: Bool
    let storage: any SecureFileStoring
    let photoLoader: ViewerPhotoLoader
    let onPhotoTap: () -> Void
    let onPhotoZoomChanged: (Bool) -> Void
    let onVideoPlaybackChanged: (Bool) -> Void
    var thumbnailService: ThumbnailService?
    /// A dismiss drag is lifting this page out of the viewer, so only the media itself is drawn.
    var isLifted = false

    var body: some View {
        switch media.mediaType {
        case .photo:
            SecurePhotoPage(
                media: media,
                isActive: isActive,
                photoLoader: photoLoader,
                thumbnailService: thumbnailService,
                isLifted: isLifted,
                onTap: onPhotoTap,
                onZoomChanged: onPhotoZoomChanged
            )
        case .video:
            SecureVideoPage(
                media: media,
                isActive: isActive,
                shouldPrepare: shouldPrepare,
                storage: storage,
                thumbnailService: thumbnailService,
                onPlaybackChanged: onVideoPlaybackChanged
            )
        }
    }
}

private struct SecurePhotoPage: View {
    let media: VaultMedia
    let isActive: Bool
    let photoLoader: ViewerPhotoLoader
    let thumbnailService: ThumbnailService?
    let isLifted: Bool
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            QuietFrameTheme.background
                .opacity(isLifted ? 0 : 1)
            if let image = photoLoader.image(for: media.id) {
                if isActive {
                    ZoomablePhotoView(
                        image: image,
                        accessibilityLabel: media.accessibilitySummary,
                        onZoomChanged: onZoomChanged
                    )
                    .opacity(isLifted ? 0 : 1)
                    .overlay {
                        if isLifted {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .accessibilityHidden(true)
                        }
                    }
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(media.accessibilitySummary)
                }
            } else if let errorMessage = photoLoader.failureMessage(for: media.id) {
                ContentUnavailableView(
                    "Photo unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(errorMessage)
                )
                .foregroundStyle(QuietFrameTheme.ink, QuietFrameTheme.quietInk)
            } else if let thumbnail = thumbnailService?.cachedImage(for: media) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                            .tint(QuietFrameTheme.ink)
                            .padding(10)
                            .background(QuietFrameTheme.background.opacity(0.6), in: Circle())
                            .accessibilityLabel("Decrypting photo")
                    }
            } else {
                ProgressView()
                    .tint(QuietFrameTheme.ink)
                    .accessibilityLabel("Decrypting photo")
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { if isActive { onTap() } })
    }
}

private struct SecureVideoPage: View {
    let media: VaultMedia
    let isActive: Bool
    let shouldPrepare: Bool
    let storage: any SecureFileStoring
    let thumbnailService: ThumbnailService?
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
            QuietFrameTheme.background
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
                    }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Video unavailable",
                    systemImage: "video.slash",
                    description: Text(errorMessage)
                )
                .foregroundStyle(QuietFrameTheme.ink, QuietFrameTheme.quietInk)
            } else if let thumbnail = thumbnailService?.cachedImage(for: media) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(QuietFrameTheme.ink)
                                .padding(10)
                                .background(QuietFrameTheme.background.opacity(0.6), in: Circle())
                                .accessibilityLabel("Preparing encrypted video")
                        }
                    }
            } else if isLoading {
                ProgressView()
                    .tint(QuietFrameTheme.ink)
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
        .task(id: playbackLifecycle) {
            switch videoPageAction(shouldPrepare: shouldPrepare, isActive: isActive, scenePhase: scenePhase) {
            case .cleanup:
                cleanup()
            case .pause:
                pausePlayback()
            case .load:
                await loadWhenReady()
            case .idle:
                break
            }
        }
        .task(id: playbackStatus) {
            await reportPlaybackStatus()
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

    private func reportPlaybackStatus() async {
        guard isActive else { return }
        if playbackStatus == .paused {
            // AVKit holds the rate at zero while scrubbing, so report a pause only once the playhead settles.
            var lastTime = player?.currentTime() ?? .zero
            while true {
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                } catch {
                    return
                }
                let currentTime = player?.currentTime() ?? .zero
                if CMTimeCompare(currentTime, lastTime) == 0 { break }
                lastTime = currentTime
            }
        }
        onPlaybackChanged(playbackStatus != .paused)
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

    private struct PlaybackLifecycle: Equatable {
        let isActive: Bool
        let scenePhase: ScenePhase
    }

    private var playbackLifecycle: PlaybackLifecycle? {
        guard shouldPrepare else { return nil }
        return PlaybackLifecycle(isActive: isActive, scenePhase: scenePhase)
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
        controller.view.backgroundColor = QuietFrameTheme.nightUI
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
