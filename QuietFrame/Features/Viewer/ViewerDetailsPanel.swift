import SwiftUI
import UIKit

/// Where the details panel starts, in viewer coordinates: just under half the viewer, clear of the top bar.
func detailsPanelTop(viewerHeight: CGFloat, topBarBottom: CGFloat) -> CGFloat {
    guard viewerHeight > 0 else { return 0 }
    return min(max(viewerHeight * 0.47, topBarBottom + 120), viewerHeight)
}

/// How far the fitted media moves up so its bottom edge rests on the details panel; never down.
func detailsMediaOffset(mediaSize: CGSize, viewerBounds: CGRect, panelTop: CGFloat) -> CGFloat {
    let fitted = aspectFitRect(imageSize: mediaSize, in: viewerBounds)
    return min(0, panelTop - fitted.maxY)
}

func shouldOpenDetails(translation: CGFloat, velocity: CGFloat) -> Bool {
    translation < -60 || (translation < -12 && velocity < -500)
}

func shouldCloseDetails(translation: CGFloat, velocity: CGFloat) -> Bool {
    translation > 40 || (translation > 12 && velocity > 400)
}

/// "3024 × 4032" in the orientation the media is shown in. Stored photo dimensions ignore EXIF orientation,
/// so they are swapped when the decoded image is clearly portrait where they are landscape, or the reverse.
func viewerDimensions(pixelWidth: Int, pixelHeight: Int, displaySize: CGSize) -> String {
    let isTurned = (pixelWidth > pixelHeight && displaySize.height > displaySize.width)
        || (pixelHeight > pixelWidth && displaySize.width > displaySize.height)
    let width = isTurned ? pixelHeight : pixelWidth
    let height = isTurned ? pixelWidth : pixelHeight
    return "\(width) \u{00D7} \(height)"
}

/// The media's details on the night ground below the raised media.
struct ViewerDetailsPanel: View {
    let media: VaultMedia
    /// The size the media is drawn at, which carries the orientation its stored dimensions may lack.
    let displaySize: CGSize
    let onClose: () -> Void

    @AccessibilityFocusState private var headingIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
                Text(viewerCaption(for: media.viewerDate).title)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(QuietFrameTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingIsFocused)

                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        LabeledContent(row.title, value: row.value)
                            .accessibilityElement(children: .combine)
                    }
                }
                .labeledContentStyle(ViewerDetailRowStyle())
            }
            .padding(QuietFrameTheme.pagePadding)
            .frame(maxWidth: QuietFrameTheme.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(QuietFrameTheme.background, ignoresSafeAreaEdges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media information")
        .accessibilityAction(named: "Close details", onClose)
        .accessibilityAction(.escape, onClose)
        .task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            headingIsFocused = true
        }
    }

    private var rows: [ViewerDetailRow] {
        var rows: [ViewerDetailRow] = []
        if let originalCreationDate = media.originalCreationDate {
            rows.append(ViewerDetailRow(title: "Taken", value: viewerLongDate(originalCreationDate)))
        }
        rows.append(ViewerDetailRow(
            title: "Imported",
            value: media.importedAt.formatted(date: .long, time: .shortened)
        ))
        rows.append(ViewerDetailRow(title: "Album", value: media.album?.name ?? "No album"))
        rows.append(ViewerDetailRow(
            title: "Dimensions",
            value: viewerDimensions(
                pixelWidth: media.pixelWidth,
                pixelHeight: media.pixelHeight,
                displaySize: displaySize
            )
        ))
        rows.append(ViewerDetailRow(
            title: "Size",
            value: ByteCountFormatter.string(fromByteCount: media.byteCount, countStyle: .file)
        ))
        if media.mediaType == .video, let duration = media.duration {
            rows.append(ViewerDetailRow(title: "Duration", value: formattedPlaybackTime(duration.rounded())))
        }
        if let originalFilename = media.originalFilename, !originalFilename.isEmpty {
            rows.append(ViewerDetailRow(title: "Original name", value: originalFilename))
        }
        if let trashedAt = media.trashedAt {
            rows.append(ViewerDetailRow(
                title: "Deleted",
                value: trashedAt.formatted(date: .long, time: .shortened)
            ))
        }
        rows.append(ViewerDetailRow(title: "Storage", value: "Encrypted on this \(UIDevice.current.model)"))
        return rows
    }
}

private struct ViewerDetailRow: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private struct ViewerDetailRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewerDetailRowLayout(label: configuration.label, value: configuration.content)
    }
}

/// Label and value side by side on a Slate hairline, a long value wrapping in the trailing column.
/// At accessibility sizes they stack once they no longer fit on one line.
private struct ViewerDetailRowLayout<RowLabel: View, RowValue: View>: View {
    let label: RowLabel
    let value: RowValue

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    sideBySide(valueWraps: false)
                    stacked
                }
            } else {
                sideBySide(valueWraps: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(QuietFrameTheme.separator)
                .frame(height: 1)
        }
    }

    private var styledLabel: some View {
        label
            .font(.subheadline)
            .foregroundStyle(QuietFrameTheme.quietInk)
    }

    private var styledValue: some View {
        value
            .font(.subheadline)
            .foregroundStyle(QuietFrameTheme.ink)
            .monospacedDigit()
    }

    private func sideBySide(valueWraps: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            styledLabel
                .fixedSize()
            Spacer(minLength: QuietFrameTheme.contentSpacing)
            styledValue
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: !valueWraps, vertical: true)
                .layoutPriority(1)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            styledLabel
            styledValue
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
