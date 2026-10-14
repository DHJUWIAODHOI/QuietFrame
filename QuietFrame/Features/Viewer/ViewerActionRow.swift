import SwiftUI

enum ViewerAction {
    case favorite
    case share
    case saveToPhotos
    case move
    case moveToTrash
    case restore
    case deletePermanently
    case togglePlayback
}

/// A bare SF Symbol on a 44-point hit area, as used across the viewer chrome.
struct ViewerGlyph: View {
    let systemName: String
    var size: CGFloat = 22
    var weight: Font.Weight = .regular
    var color: Color = QuietFrameTheme.ink

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(width: QuietFrameTheme.controlHeight, height: QuietFrameTheme.controlHeight)
            .contentShape(Rectangle())
    }
}

struct ViewerGlyphButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.45)
    }
}

/// Icon-only actions under the media. A video's play button sits in the middle of the row.
struct ViewerActionRow: View {
    let media: VaultMedia
    let isWorking: Bool
    let isPlaying: Bool
    let canPlay: Bool
    let perform: (ViewerAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if media.isTrashed {
                if media.mediaType == .video {
                    restoreButton
                        .frame(maxWidth: .infinity)
                    playButton
                    HStack(spacing: 0) {
                        exportMenu
                            .frame(maxWidth: .infinity)
                        deleteButton
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    restoreButton
                    Spacer(minLength: 0)
                    exportMenu
                    Spacer(minLength: 0)
                    deleteButton
                }
            } else {
                favoriteButton
                Spacer(minLength: 0)
                exportMenu
                Spacer(minLength: 0)
                if media.mediaType == .video {
                    playButton
                    Spacer(minLength: 0)
                }
                moveButton
                Spacer(minLength: 0)
                trashButton
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: QuietFrameTheme.controlHeight)
    }

    private var favoriteButton: some View {
        glyphButton(
            media.isFavorite ? "Unfavorite" : "Favorite",
            systemImage: media.isFavorite ? "heart.fill" : "heart",
            color: media.isFavorite ? QuietFrameTheme.accent : QuietFrameTheme.ink,
            action: .favorite
        )
    }

    private var moveButton: some View {
        glyphButton("Move", systemImage: "folder", action: .move)
    }

    private var trashButton: some View {
        glyphButton("Move to Trash", systemImage: "trash", color: QuietFrameTheme.destructive, action: .moveToTrash)
    }

    private var restoreButton: some View {
        glyphButton("Restore", systemImage: "arrow.uturn.backward", action: .restore)
    }

    private var deleteButton: some View {
        glyphButton(
            "Delete permanently",
            systemImage: "trash.slash",
            color: QuietFrameTheme.destructive,
            action: .deletePermanently
        )
    }

    private var playButton: some View {
        glyphButton(
            isPlaying ? "Pause" : "Play",
            systemImage: isPlaying ? "pause.fill" : "play.fill",
            size: 28,
            action: .togglePlayback
        )
        .disabled(!canPlay)
        .accessibilityAddTraits(isPlaying ? [] : .startsMediaSession)
    }

    private var exportMenu: some View {
        Menu {
            Button("Share", systemImage: "square.and.arrow.up") { perform(.share) }
            Button("Save to Photos", systemImage: "photo.badge.arrow.down") { perform(.saveToPhotos) }
        } label: {
            ViewerGlyph(systemName: "square.and.arrow.up")
        }
        .disabled(isWorking)
        .opacity(isWorking ? 0.45 : 1)
        .accessibilityLabel("Export")
        .accessibilityShowsLargeContentViewer {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private func glyphButton(
        _ title: String,
        systemImage: String,
        size: CGFloat = 22,
        color: Color = QuietFrameTheme.ink,
        action: ViewerAction
    ) -> some View {
        Button {
            perform(action)
        } label: {
            ViewerGlyph(systemName: systemImage, size: size, color: color)
        }
        .buttonStyle(ViewerGlyphButtonStyle())
        .accessibilityLabel(title)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}
