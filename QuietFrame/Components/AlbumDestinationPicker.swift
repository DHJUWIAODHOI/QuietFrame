import SwiftUI

struct AlbumDestinationPicker: View {
    let albums: [VaultAlbum]
    let currentAlbumID: UUID?
    let choose: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("No album", systemImage: "rectangle.stack.badge.minus") {
                        choose(nil)
                    }
                    .disabled(currentAlbumID == nil)
                    .opacity(currentAlbumID == nil ? 0.45 : 1)
                }
                .quietRows()

                Section {
                    ForEach(albums) { album in
                        let isCurrent = album.id == currentAlbumID
                        Button {
                            choose(album.id)
                        } label: {
                            HStack(spacing: QuietFrameTheme.contentSpacing) {
                                Label(album.name, systemImage: "rectangle.stack")
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: QuietFrameTheme.compactSpacing)
                                if isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(QuietFrameTheme.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .disabled(isCurrent)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                .quietRows()
            }
            .labelStyle(QuietSettingsLabelStyle())
            .listStyle(.insetGrouped)
            .quietFormStyle()
            .navigationTitle("Move to album")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
