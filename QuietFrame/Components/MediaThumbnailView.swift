import SwiftUI
import UIKit

struct MediaThumbnailView: View {
    let media: VaultMedia
    let thumbnailService: ThumbnailService
    /// The tile's width in points; nothing loads until it is known.
    var tileWidth: CGFloat?
    var isSelected = false
    var selectionMode = false
    var thumbnailAspectRatio: CGFloat = 1

    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .caption) private var badgeSize: CGFloat = 24
    @State private var image: UIImage?

    private static let badgeInset: CGFloat = 6

    private struct ThumbnailRequest: Equatable {
        let identifier: String?
        let pixelSize: Int?
        let cacheGeneration: UInt64
    }

    private var pixelSize: Int? {
        guard let tileWidth else { return nil }
        let longestTileSide = tileWidth * max(1, 1 / max(thumbnailAspectRatio, 0.01))
        return ThumbnailService.pixelSize(
            fillingSquareOf: longestTileSide,
            scale: displayScale,
            mediaPixelSize: CGSize(width: media.pixelWidth, height: media.pixelHeight)
        )
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous)
    }

    private var videoDuration: TimeInterval? {
        media.mediaType == .video ? media.duration : nil
    }

    var body: some View {
        ZStack {
            // The image sets the minimum height; badges can grow the tile at large text sizes.
            Color.clear.aspectRatio(thumbnailAspectRatio, contentMode: .fit)

            VStack(spacing: Self.badgeInset) {
                if selectionMode || isSelected {
                    selectionBadge
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
                bottomBadges
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Self.badgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { thumbnail }
        .clipShape(tileShape)
        .overlay {
            if isSelected {
                tileShape
                    .strokeBorder(QuietFrameTheme.accent, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(tileShape)
        .task(id: ThumbnailRequest(
            identifier: media.thumbnailIdentifier,
            pixelSize: pixelSize,
            cacheGeneration: thumbnailService.generation
        )) {
            guard let pixelSize else { return }
            let loaded = await thumbnailService.image(for: media, pixelSize: pixelSize)
            if !Task.isCancelled { image = loaded }
        }
        .onDisappear { image = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(selectionMode ? (isSelected ? "Selected" : "Not selected") : "")
    }

    /// A tile that comes back into view shows a cached image straight away instead of a placeholder.
    private var displayedImage: UIImage? {
        if let image { return image }
        guard let pixelSize else { return nil }
        return thumbnailService.cachedImage(for: media, pixelSize: pixelSize)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = displayedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            QuietFrameTheme.elevated
                .overlay {
                    Image(systemName: media.mediaType.symbolName)
                        .font(.title3)
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(QuietFrameTheme.background)
                .frame(width: badgeSize, height: badgeSize)
                .background(QuietFrameTheme.accent, in: Circle())
        } else {
            Circle()
                .fill(QuietFrameTheme.background.opacity(0.55))
                .overlay {
                    Circle().strokeBorder(QuietFrameTheme.ink, lineWidth: 1.5)
                }
                .frame(width: badgeSize, height: badgeSize)
        }
    }

    private var bottomBadges: some View {
        VStack(alignment: .leading, spacing: Self.badgeInset) {
            if let trashedAt = media.trashedAt {
                Label(trashedAt.formatted(date: .abbreviated, time: .omitted), systemImage: "trash.fill")
                    .labelStyle(.titleAndIcon)
                    .thumbnailBadgeBackground()
            }
            if media.isFavorite || videoDuration != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 0) {
                        if media.isFavorite {
                            favoriteBadge
                        }
                        Spacer(minLength: 4)
                        if let videoDuration {
                            durationBadge(videoDuration)
                                .layoutPriority(1)
                        }
                    }

                    VStack(alignment: .leading, spacing: Self.badgeInset) {
                        if media.isFavorite {
                            favoriteBadge
                        }
                        if let videoDuration {
                            durationBadge(videoDuration)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(QuietFrameTheme.ink)
    }

    private var favoriteBadge: some View {
        Image(systemName: "heart.fill")
            .font(.caption2.weight(.semibold))
            .frame(width: badgeSize, height: badgeSize)
            .background(QuietFrameTheme.background.opacity(0.78), in: Circle())
    }

    private func durationBadge(_ duration: TimeInterval) -> some View {
        Text(formattedDuration(duration))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .thumbnailBadgeBackground()
    }

    private var accessibilitySummary: String {
        guard let trashedAt = media.trashedAt else { return media.accessibilitySummary }
        return "\(media.accessibilitySummary), deleted \(trashedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension View {
    func thumbnailBadgeBackground() -> some View {
        padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(QuietFrameTheme.background.opacity(0.78), in: Capsule())
    }
}
