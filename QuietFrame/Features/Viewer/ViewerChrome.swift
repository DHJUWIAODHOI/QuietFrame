import SwiftUI

/// The Edge chrome: a top bar and the bottom controls on soft night scrims that dissolve into the media.
struct ViewerChrome: View {
    let media: VaultMedia?
    let items: [VaultMedia]
    /// The position of `media` in `items`, looked up once by the viewer.
    let selectedIndex: Int?
    let thumbnailService: ThumbnailService
    let playback: ViewerVideoPlayback
    let isWorking: Bool
    let detailsAreOpen: Bool
    let safeAreaInsets: EdgeInsets
    let infoButtonFocus: AccessibilityFocusState<Bool>.Binding
    let onClose: () -> Void
    let onToggleDetails: () -> Void
    let onSelect: (UUID) -> Void
    let onAction: (ViewerAction) -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    /// The bottom controls leave before the details panel has risen over them, and return more slowly.
    private var detailsFade: Animation {
        ViewerZoomMotion.easeOut(duration: detailsAreOpen ? 0.16 : 0.28)
    }

    var body: some View {
        ZStack {
            bottomScrim
            VStack(spacing: 0) {
                ViewerTopBar(
                    media: media,
                    detailsAreOpen: detailsAreOpen,
                    infoButtonFocus: infoButtonFocus,
                    onClose: onClose,
                    onToggleDetails: onToggleDetails
                )
                .background { topScrim }
                Spacer(minLength: 0)
                if let media {
                    bottomControls(for: media)
                        .opacity(detailsAreOpen ? 0 : 1)
                        .animation(detailsFade, value: detailsAreOpen)
                        .allowsHitTesting(!detailsAreOpen)
                        .accessibilityHidden(detailsAreOpen)
                }
            }
        }
        .foregroundStyle(QuietFrameTheme.ink)
        .tint(QuietFrameTheme.ink)
        .environment(\.colorScheme, .dark)
    }

    /// Reaches from the top of the screen to a fixed distance below the bar, so it grows with large text.
    private var topScrim: some View {
        LinearGradient(
            stops: [
                .init(color: QuietFrameTheme.night.opacity(0.88), location: 0),
                .init(color: QuietFrameTheme.night.opacity(0.8), location: 0.5),
                .init(color: QuietFrameTheme.night.opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .padding(.bottom, isCompactHeight ? -28 : -62)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bottomScrim: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: QuietFrameTheme.night.opacity(0), location: 0),
                    .init(color: QuietFrameTheme.night.opacity(0.8), location: 0.5),
                    .init(color: QuietFrameTheme.night.opacity(0.88), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: safeAreaInsets.bottom + (isCompactHeight ? 150 : 196))
            .opacity(detailsAreOpen ? 0 : 1)
            .animation(detailsFade, value: detailsAreOpen)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func bottomControls(for media: VaultMedia) -> some View {
        VStack(spacing: isCompactHeight ? QuietFrameTheme.compactSpacing : 12) {
            if media.mediaType == .video || items.count > 1 {
                Group {
                    if media.mediaType == .video {
                        ViewerScrubber(media: media, playback: playback, thumbnailService: thumbnailService)
                            .padding(.horizontal, QuietFrameTheme.pagePadding)
                    } else {
                        ViewerFilmstrip(
                            items: items,
                            selectedMediaID: media.id,
                            selectedIndex: selectedIndex,
                            thumbnailService: thumbnailService,
                            onSelect: onSelect
                        )
                    }
                }
                .background {
                    if items.count > 1 {
                        ViewerMediaPosition(items: items, selectedIndex: selectedIndex, onSelect: onSelect)
                    }
                }
            }
            ViewerActionRow(
                media: media,
                isWorking: isWorking,
                isPlaying: playback.isPlaying,
                canPlay: playback.unavailableMediaID != media.id,
                perform: onAction
            )
        }
        .frame(maxWidth: QuietFrameTheme.readableWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, safeAreaInsets.bottom > 0 ? 0 : QuietFrameTheme.compactSpacing)
    }
}

/// The filmstrip's VoiceOver element. It stays in place when the scrubber replaces the strip for a video,
/// so focus survives stepping between photos and videos.
private struct ViewerMediaPosition: View {
    let items: [VaultMedia]
    let selectedIndex: Int?
    let onSelect: (UUID) -> Void

    private var positionDescription: String {
        guard let selectedIndex else { return "" }
        return "\(selectedIndex + 1) of \(items.count)"
    }

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("Media position")
            .accessibilityValue(positionDescription)
            .accessibilityAdjustableAction { direction in
                guard let selectedIndex else { return }
                if direction == .increment, selectedIndex + 1 < items.count {
                    onSelect(items[selectedIndex + 1].id)
                } else if direction == .decrement, selectedIndex > 0 {
                    onSelect(items[selectedIndex - 1].id)
                }
            }
    }
}

/// Close, the capture date and the details toggle, over the top scrim.
struct ViewerTopBar: View {
    let media: VaultMedia?
    let detailsAreOpen: Bool
    let infoButtonFocus: AccessibilityFocusState<Bool>.Binding
    let onClose: () -> Void
    let onToggleDetails: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        HStack(spacing: QuietFrameTheme.compactSpacing) {
            Button(action: onClose) {
                ViewerGlyph(systemName: "chevron.left", size: 20, weight: .medium)
            }
            .buttonStyle(ViewerGlyphButtonStyle())
            .accessibilityLabel("Close viewer")
            .accessibilityShowsLargeContentViewer {
                Label("Close viewer", systemImage: "chevron.left")
            }

            Group {
                if let media {
                    caption(viewerCaption(for: media.viewerDate))
                }
            }
            .frame(maxWidth: .infinity)

            if media != nil {
                Button(action: onToggleDetails) {
                    ViewerGlyph(
                        systemName: "info.circle",
                        size: 20,
                        color: detailsAreOpen ? QuietFrameTheme.accent : QuietFrameTheme.ink
                    )
                }
                .buttonStyle(ViewerGlyphButtonStyle())
                .accessibilityLabel("Media information")
                .accessibilityValue(detailsAreOpen ? "Shown" : "Hidden")
                .accessibilityShowsLargeContentViewer {
                    Label("Media information", systemImage: "info.circle")
                }
                .accessibilityFocused(infoButtonFocus)
            } else {
                Color.clear
                    .frame(width: QuietFrameTheme.controlHeight, height: QuietFrameTheme.controlHeight)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: QuietFrameTheme.controlHeight)
    }

    private var captionLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact ? 2 : 1
    }

    private func caption(_ text: (title: String, subtitle: String)) -> some View {
        VStack(spacing: 2) {
            Text(text.title)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(QuietFrameTheme.ink)
            Text(text.subtitle)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(QuietFrameTheme.quietInk)
        }
        .lineLimit(captionLineLimit)
        .truncationMode(.tail)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
