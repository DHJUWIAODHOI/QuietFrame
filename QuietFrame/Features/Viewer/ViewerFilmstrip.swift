import SwiftUI
import UIKit

private let filmstripTileWidth: CGFloat = 28
private let filmstripSelectedTileWidth: CGFloat = 52
private let filmstripTileHeight: CGFloat = 40
private let filmstripSpacing: CGFloat = 3
private let filmstripHeight: CGFloat = 48
private let filmstripEdgeFade: CGFloat = 32

/// The item indexes drawn in the filmstrip: the selected item and up to `perSide` neighbours on each side.
func filmstripWindow(selectedIndex: Int, count: Int, perSide: Int) -> Range<Int> {
    guard count > 0, (0..<count).contains(selectedIndex) else { return 0..<0 }
    let side = max(perSide, 0)
    return max(selectedIndex - side, 0)..<min(selectedIndex + side + 1, count)
}

/// Enough neighbours on each side of the centred selected tile to reach the edges of a strip `width` wide.
func filmstripTilesPerSide(width: CGFloat) -> Int {
    guard width.isFinite, width > 0 else { return 1 }
    let halfWidth = max(width / 2 - filmstripSelectedTileWidth / 2, 0)
    return Int((halfWidth / (filmstripTileWidth + filmstripSpacing)).rounded(.up)) + 1
}

/// Whether the tile `distance` places from the selected one is centred clear of the strip's faded edge.
/// Tiles further out are masked away or lie past the strip, so they must not take taps.
func filmstripTileIsTappable(distance: Int, stripWidth: CGFloat) -> Bool {
    guard distance > 0 else { return true }
    let centre = filmstripSelectedTileWidth / 2
        + CGFloat(distance) * (filmstripTileWidth + filmstripSpacing)
        - filmstripTileWidth / 2
    return centre <= stripWidth / 2 - filmstripEdgeFade / 2
}

/// The brass-marked strip of neighbouring items under a photo, with the selected item centred.
/// VoiceOver reads it through `ViewerChrome`'s "Media position" element instead of its tiles.
struct ViewerFilmstrip: View {
    let items: [VaultMedia]
    let selectedMediaID: UUID
    let selectedIndex: Int?
    let thumbnailService: ThumbnailService
    let onSelect: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if let selectedIndex {
                strip(selectedIndex: selectedIndex, width: proxy.size.width)
            }
        }
        .frame(height: filmstripHeight)
        .accessibilityHidden(true)
    }

    private func strip(selectedIndex: Int, width: CGFloat) -> some View {
        let window = filmstripWindow(
            selectedIndex: selectedIndex,
            count: items.count,
            perSide: filmstripTilesPerSide(width: width)
        )
        let leadingCount = selectedIndex - window.lowerBound
        let trailingCount = window.upperBound - selectedIndex - 1
        let centeringOffset = CGFloat(trailingCount - leadingCount) * (filmstripTileWidth + filmstripSpacing) / 2

        return ZStack(alignment: .top) {
            HStack(alignment: .top, spacing: filmstripSpacing) {
                ForEach(Array(items[window].enumerated()), id: \.element.id) { offset, media in
                    Button {
                        onSelect(media.id)
                    } label: {
                        FilmstripTile(
                            media: media,
                            thumbnailService: thumbnailService,
                            isSelected: media.id == selectedMediaID
                        )
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(filmstripTileIsTappable(
                        distance: abs(window.lowerBound + offset - selectedIndex),
                        stripWidth: width
                    ))
                }
            }
            .fixedSize()
            .offset(x: centeringOffset)

            RoundedRectangle(cornerRadius: 1)
                .fill(QuietFrameTheme.accent)
                .frame(width: filmstripSelectedTileWidth, height: 2)
                .padding(.top, filmstripHeight - 2)
        }
        .frame(width: width, height: filmstripHeight, alignment: .top)
        .mask {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [QuietFrameTheme.night.opacity(0), QuietFrameTheme.night],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: filmstripEdgeFade)
                QuietFrameTheme.night
                LinearGradient(
                    colors: [QuietFrameTheme.night, QuietFrameTheme.night.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: filmstripEdgeFade)
            }
        }
        .animation(reduceMotion ? nil : ViewerZoomMotion.easeOut(duration: 0.24), value: selectedMediaID)
    }
}

private struct FilmstripTile: View {
    let media: VaultMedia
    let thumbnailService: ThumbnailService
    let isSelected: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var pixelSize: Int {
        ThumbnailService.pixelSize(
            fillingSquareOf: max(filmstripSelectedTileWidth, filmstripTileHeight),
            scale: displayScale,
            mediaPixelSize: CGSize(width: media.pixelWidth, height: media.pixelHeight)
        )
    }

    var body: some View {
        let thumbnail = image ?? thumbnailService.cachedImage(for: media)
        QuietFrameTheme.elevated
            .frame(width: isSelected ? filmstripSelectedTileWidth : filmstripTileWidth, height: filmstripTileHeight)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(isSelected ? 1 : 0.7)
            .frame(height: filmstripHeight, alignment: .top)
            .contentShape(Rectangle())
            .task(id: "\(media.id)#\(thumbnailService.generation)") {
                let loaded = await thumbnailService.image(for: media, pixelSize: pixelSize)
                if !Task.isCancelled { image = loaded }
            }
    }
}
