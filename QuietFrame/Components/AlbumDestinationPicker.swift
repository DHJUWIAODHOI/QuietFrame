import SwiftUI

struct AlbumDestinationPicker: View {
    let albums: [VaultAlbum]
    let currentAlbumID: UUID?
    let choose: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button("No Album", systemImage: "rectangle.stack.badge.minus") {
                    choose(nil)
                }
                .disabled(currentAlbumID == nil)
                .listRowBackground(QuietFrameTheme.elevated)

                ForEach(albums) { album in
                    Button {
                        choose(album.id)
                    } label: {
                        HStack(spacing: QuietFrameTheme.contentSpacing) {
                            Label(album.name, systemImage: "rectangle.stack")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: QuietFrameTheme.compactSpacing)
                            if album.id == currentAlbumID {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .disabled(album.id == currentAlbumID)
                    .accessibilityAddTraits(album.id == currentAlbumID ? .isSelected : [])
                    .listRowBackground(QuietFrameTheme.elevated)
                }
            }
            .labelStyle(QuietSettingsLabelStyle())
            .listStyle(.insetGrouped)
            .quietFormStyle()
            .navigationTitle("Move to Album")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
