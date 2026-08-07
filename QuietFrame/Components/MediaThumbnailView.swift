import SwiftUI
import UIKit

struct MediaThumbnailView: View {
    let media: VaultMedia
    let thumbnailService: ThumbnailService
    var isSelected = false
    var selectionMode = false

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [.secondary.opacity(0.18), .secondary.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: media.mediaType.symbolName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if media.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .accessibilityHidden(true)
            }

            if media.mediaType == .video, let duration = media.duration {
                Label(formattedDuration(duration), systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.66), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(7)
            }

            if let trashedAt = media.trashedAt {
                Label(trashedAt.formatted(date: .abbreviated, time: .omitted), systemImage: "trash.fill")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.66), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(7)
            }

            if isSelected {
                Color.accentColor.opacity(0.22)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 3)
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(7)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: media.thumbnailIdentifier) {
            image = await thumbnailService.image(for: media)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(media.accessibilitySummary)
        .accessibilityValue(selectionMode ? (isSelected ? "Selected" : "Not selected") : "")
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
