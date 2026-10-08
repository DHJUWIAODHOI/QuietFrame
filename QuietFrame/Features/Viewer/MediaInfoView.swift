import SwiftUI
import UniformTypeIdentifiers

struct MediaInfoView: View {
    let media: VaultMedia
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let filename = media.originalFilename {
                        infoRow("Filename", filename)
                    }
                    infoRow("Type", typeDescription)
                    infoRow("Dimensions", "\(media.pixelWidth) \u{00D7} \(media.pixelHeight)")
                    infoRow("File size", ByteCountFormatter.string(fromByteCount: media.byteCount, countStyle: .file))
                    if let duration = media.duration {
                        infoRow("Duration", formattedDuration(duration))
                    }
                } header: {
                    sectionHeader("Media")
                }
                .quietRows()

                Section {
                    infoRow("Imported", media.importedAt.formatted(date: .long, time: .shortened))
                    if let originalCreationDate = media.originalCreationDate {
                        infoRow("Created", originalCreationDate.formatted(date: .long, time: .shortened))
                    }
                    if let trashedAt = media.trashedAt {
                        infoRow("Deleted", trashedAt.formatted(date: .long, time: .shortened))
                    }
                } header: {
                    sectionHeader("Dates")
                }
                .quietRows()

                Section {
                    infoRow("Album", media.album?.name ?? "No album")
                    infoRow("Favorite", media.isFavorite ? "Yes" : "No")
                    if !media.tags.isEmpty {
                        infoRow("Tags", media.tags.joined(separator: ", "))
                    }
                } header: {
                    sectionHeader("Organization")
                }
                .quietRows()
            }
            .labeledContentStyle(MediaInfoRowStyle())
            .quietFormStyle()
            .navigationTitle("Media information")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(QuietFrameTheme.sectionTitleFont)
            .foregroundStyle(QuietFrameTheme.ink)
            .textCase(nil)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
            .accessibilityElement(children: .combine)
    }

    private var typeDescription: String {
        UTType(media.contentTypeIdentifier)?.localizedDescription
            ?? (media.mediaType == .photo ? "Photo" : "Video")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MediaInfoRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .foregroundStyle(QuietFrameTheme.quietInk)
        let value = configuration.content
            .foregroundStyle(QuietFrameTheme.ink)
            .monospacedDigit()

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: QuietFrameTheme.contentSpacing) {
                label.fixedSize()
                Spacer(minLength: QuietFrameTheme.compactSpacing)
                value.fixedSize()
            }
            VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
                label
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
