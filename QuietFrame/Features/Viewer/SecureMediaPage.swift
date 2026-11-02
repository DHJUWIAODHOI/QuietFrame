import AVFoundation
import SwiftUI
import UIKit
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
    let playback: ViewerVideoPlayback
    let onTap: () -> Void
    let onPhotoZoomChanged: (Bool) -> Void
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
                onTap: onTap,
                onZoomChanged: onPhotoZoomChanged
            )
        case .video:
            SecureVideoPage(
                media: media,
                isActive: isActive,
                shouldPrepare: shouldPrepare,
                storage: storage,
                thumbnailService: thumbnailService,
                playback: playback,
                onTap: onTap
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

    @State private var preview: UIImage?

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
            } else if let thumbnail = preview ?? thumbnailService?.cachedImage(for: media) {
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
        .task(id: media.id) {
            guard let thumbnailService, photoLoader.image(for: media.id) == nil else { return }
            let loaded = await thumbnailService.image(for: media)
            if !Task.isCancelled { preview = loaded }
        }
    }
}

private struct SecureVideoPage: View {
    let media: VaultMedia
    let isActive: Bool
    let shouldPrepare: Bool
    let storage: any SecureFileStoring
    let thumbnailService: ThumbnailService?
    let playback: ViewerVideoPlayback
    let onTap: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    @State private var stream: EncryptedVideoStream?
    @State private var streamStatus: NSKeyValueObservation?
    @State private var player: AVQueuePlayer?
    @State private var playerLooper: AVPlayerLooper?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            QuietFrameTheme.background
            if let errorMessage {
                ContentUnavailableView(
                    "Video unavailable",
                    systemImage: "video.slash",
                    description: Text(errorMessage)
                )
                .foregroundStyle(QuietFrameTheme.ink, QuietFrameTheme.quietInk)
            } else {
                if let thumbnail = poster ?? thumbnailService?.cachedImage(for: media) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(media.accessibilitySummary)
                        .accessibilityHidden(player != nil || !isActive)
                }
                if let player {
                    SecureVideoPlayerView(player: player)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(media.accessibilitySummary)
                        .accessibilityHidden(!isActive)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(QuietFrameTheme.ink)
                        .padding(10)
                        .background(QuietFrameTheme.background.opacity(0.6), in: Circle())
                        .accessibilityLabel("Preparing encrypted video")
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { if isActive { onTap() } })
        .task(id: playbackLifecycle) {
            switch videoPageAction(shouldPrepare: shouldPrepare, isActive: isActive, scenePhase: scenePhase) {
            case .cleanup:
                cleanup()
            case .pause:
                pausePlayback()
            case .load:
                await loadWhenReady()
                attachIfActive()
            case .idle:
                break
            }
        }
        .onChange(of: isActive) { _, isActive in
            if !isActive { detachPlayback() }
        }
        .task(id: media.id) {
            guard let thumbnailService else { return }
            let loaded = await thumbnailService.image(for: media)
            if !Task.isCancelled { poster = loaded }
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
            let reader = try await storage.openEncryptedReader(
                identifier: media.storageIdentifier,
                location: media.isTrashed ? .trash : .media
            )
            guard !Task.isCancelled, shouldPrepare, scenePhase == .active else {
                await reader.close()
                return
            }
            let newStream = try EncryptedVideoStream(reader: reader, contentTypeIdentifier: media.contentTypeIdentifier)
            let newPlayer = AVQueuePlayer()
            let newLooper = AVPlayerLooper(
                player: newPlayer,
                templateItem: AVPlayerItem(asset: newStream.asset)
            )
            streamStatus = newLooper.observe(\.status, options: [.new]) { looper, _ in
                guard looper.status == .failed else { return }
                Task { @MainActor in showUnplayableStream() }
            }
            stream = newStream
            playerLooper = newLooper
            player = newPlayer
        } catch is CancellationError {
            return
        } catch VaultError.importCancelled {
            return
        } catch {
            guard !Task.isCancelled, shouldPrepare else { return }
            if isActive { playback.pause() }
            playback.markUnavailable(mediaID: media.id)
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.corruptedFile.localizedDescription
        }
    }

    private func attachIfActive() {
        guard !Task.isCancelled, isActive, scenePhase == .active, let player, let stream else { return }
        playback.attach(player: player, asset: stream.asset, mediaID: media.id, fallbackDuration: media.duration)
    }

    /// A chunk that fails to decrypt mid-stream shows the same message as a file that fails to open.
    private func showUnplayableStream() {
        guard stream != nil else { return }
        let ownsTransport = playback.mediaID == media.id
        cleanup()
        if ownsTransport { playback.markUnavailable(mediaID: media.id) }
        errorMessage = VaultError.corruptedFile.localizedDescription
    }

    private func pausePlayback() {
        player?.pause()
        if isActive { playback.pause() }
    }

    private func detachPlayback() {
        player?.pause()
        playback.detach(mediaID: media.id)
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
        detachPlayback()
        playerLooper?.disableLooping()
        playerLooper = nil
        player?.removeAllItems()
        player = nil
        streamStatus?.invalidate()
        streamStatus = nil
        stream?.invalidate()
        stream = nil
        errorMessage = nil
    }
}

/// Draws the player's video aspect-fit with no controls and no gestures of its own,
/// so taps, paging and the dismiss drag reach the viewer.
private struct SecureVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> SecureVideoLayerView {
        let view = SecureVideoLayerView()
        view.player = player
        return view
    }

    func updateUIView(_ view: SecureVideoLayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleUIView(_ view: SecureVideoLayerView, coordinator: ()) {
        view.player = nil
    }
}

private final class SecureVideoLayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
    }
}
