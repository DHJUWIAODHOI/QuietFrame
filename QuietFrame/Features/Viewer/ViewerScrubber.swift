import SwiftUI
import UIKit

private let scrubberStripHeight: CGFloat = 40
private let scrubberPlayheadOverhang: CGFloat = 4

/// The video transport's frame strip with a brass playhead, and the elapsed and remaining times above it.
struct ViewerScrubber: View {
    let media: VaultMedia
    let playback: ViewerVideoPlayback
    let thumbnailService: ThumbnailService

    @State private var width: CGFloat = 0
    @GestureState private var isDragging = false

    private struct FrameRequestKey: Equatable {
        let mediaID: UUID?
        let count: Int
        let hasWidth: Bool
        let hasDuration: Bool
    }

    private var isAttached: Bool {
        playback.mediaID == media.id
    }

    private var currentTime: TimeInterval {
        isAttached ? playback.currentTime : 0
    }

    private var duration: TimeInterval {
        isAttached && playback.duration > 0 ? playback.duration : max(media.duration ?? 0, 0)
    }

    private var frameCount: Int {
        videoFrameCount(forStripWidth: width)
    }

    private var frameRequestKey: FrameRequestKey {
        FrameRequestKey(
            mediaID: playback.mediaID,
            count: frameCount,
            hasWidth: width > 0,
            hasDuration: playback.duration > 0
        )
    }

    var body: some View {
        VStack(spacing: scrubberPlayheadOverhang) {
            HStack {
                Text(formattedPlaybackTime(currentTime))
                Spacer(minLength: QuietFrameTheme.compactSpacing)
                Text("\u{2212}\(formattedPlaybackTime((duration - currentTime).rounded()))")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(QuietFrameTheme.quietInk)
            .lineLimit(1)

            ZStack(alignment: .leading) {
                frameStrip
                    .frame(height: scrubberStripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                playhead
            }
            .frame(height: scrubberStripHeight + scrubberPlayheadOverhang * 2)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
            }
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { playback.endScrub() }
        }
        .onDisappear { playback.endScrub() }
        .task(id: frameRequestKey) {
            guard isAttached, width > 0 else { return }
            playback.requestFrames(count: frameCount)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formattedPlaybackTime(currentTime)) of \(formattedPlaybackTime(duration))")
        .accessibilityAdjustableAction { direction in
            if direction == .increment {
                playback.seek(by: 5)
            } else if direction == .decrement {
                playback.seek(by: -5)
            }
        }
    }

    private var frameStrip: some View {
        let frames = isAttached ? playback.frames : []
        let placeholder = thumbnailService.cachedImage(for: media)
        return HStack(spacing: 1) {
            ForEach(0..<frameCount, id: \.self) { index in
                QuietFrameTheme.elevated
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let image = stripImage(at: index, frames: frames, placeholder: placeholder) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .clipped()
            }
        }
        .background(QuietFrameTheme.background)
    }

    private func stripImage(at index: Int, frames: [UIImage], placeholder: UIImage?) -> UIImage? {
        frames.indices.contains(index) ? frames[index] : placeholder
    }

    private var playhead: some View {
        let fraction = CGFloat(playbackFraction(at: currentTime, duration: duration))
        let x = min(max(fraction * width - 1, 0), max(width - 2, 0))
        return RoundedRectangle(cornerRadius: 1)
            .fill(QuietFrameTheme.accent)
            .frame(width: 2, height: scrubberStripHeight + scrubberPlayheadOverhang * 2)
            .background {
                RoundedRectangle(cornerRadius: 2)
                    .fill(QuietFrameTheme.background.opacity(0.5))
                    .padding(-1)
            }
            .offset(x: x)
            .allowsHitTesting(false)
    }

    /// A cancelled drag never reaches `onEnded`, so the scrub also ends when the gesture state resets.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, isDragging, _ in isDragging = true }
            .onChanged { value in
                guard width > 0 else { return }
                playback.scrub(toFraction: Double(value.location.x / width))
            }
            .onEnded { _ in
                playback.endScrub()
            }
    }
}
