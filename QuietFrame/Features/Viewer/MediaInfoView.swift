import SwiftUI
import UniformTypeIdentifiers

struct MediaInfoView: View {
    let media: VaultMedia
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Media") {
                    if let filename = media.originalFilename {
                        infoRow("Filename", filename)
                    }
                    infoRow("Type", typeDescription)
                    infoRow("Dimensions", "\(media.pixelWidth) x \(media.pixelHeight)")
                    infoRow("File Size", ByteCountFormatter.string(fromByteCount: media.byteCount, countStyle: .file))
                    if let duration = media.duration {
                        infoRow("Duration", formattedDuration(duration))
                    }
                }

                Section("Dates") {
                    infoRow("Imported", media.importedAt.formatted(date: .long, time: .shortened))
                    if let originalCreationDate = media.originalCreationDate {
                        infoRow("Created", originalCreationDate.formatted(date: .long, time: .shortened))
                    }
                    if let trashedAt = media.trashedAt {
                        infoRow("Deleted", trashedAt.formatted(date: .long, time: .shortened))
                    }
                }

                Section("Organization") {
                    infoRow("Album", media.album?.name ?? "No Album")
                    infoRow("Favorite", media.isFavorite ? "Yes" : "No")
                    if !media.tags.isEmpty {
                        infoRow("Tags", media.tags.joined(separator: ", "))
                    }
                }
            }
            .navigationTitle("Media Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
