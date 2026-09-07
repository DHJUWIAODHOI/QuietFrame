import SwiftUI
import UIKit

struct MediaThumbnailView: View {
    let media: VaultMedia
    let thumbnailService: ThumbnailService
    var isSelected = false
    var selectionMode = false
    var thumbnailAspectRatio: CGFloat = 1

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            // The image sets the minimum height; badges can grow the tile at large text sizes.
            Color.clear.aspectRatio(thumbnailAspectRatio, contentMode: .fit)

            VStack(spacing: QuietFrameTheme.compactSpacing / 2) {
                HStack(alignment: .top, spacing: QuietFrameTheme.compactSpacing / 2) {
                    if media.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.8), in: Circle())
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, QuietFrameTheme.accent)
                    }
                }
                Spacer(minLength: QuietFrameTheme.compactSpacing / 2)
                VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing / 2) {
                    if media.mediaType == .video, let duration = media.duration {
                        Label(formattedDuration(duration), systemImage: "play.fill")
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let trashedAt = media.trashedAt {
                        Label(trashedAt.formatted(date: .abbreviated, time: .omitted), systemImage: "trash.fill")
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(QuietFrameTheme.compactSpacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                QuietFrameTheme.inset
                    .overlay {
                        Image(systemName: media.mediaType.symbolName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous)
                    .strokeBorder(QuietFrameTheme.accent, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous))
        .task(id: media.thumbnailIdentifier) {
            image = await thumbnailService.image(for: media)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(selectionMode ? (isSelected ? "Selected" : "Not selected") : "")
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
