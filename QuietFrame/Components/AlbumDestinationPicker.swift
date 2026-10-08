import SwiftUI

struct AlbumDestinationPicker: View {
    let albums: [VaultAlbum]
    let currentAlbumID: UUID?
    var title: String = "Move to album"
    var noAlbumTitle: String = "No album"
    var disablesCurrentChoice: Bool = true
    var createAlbum: (@MainActor (String) throws -> UUID)? = nil
    let choose: (UUID?) -> Void

    @State private var showsNewAlbum = false
    @State private var newAlbumName = ""
    @State private var userMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if createAlbum != nil {
                    Section {
                        Button("New album", systemImage: "plus") {
                            newAlbumName = ""
                            showsNewAlbum = true
                        }
                    }
                    .quietRows()
                }

                Section {
                    let noAlbumIsDisabled = disablesCurrentChoice && currentAlbumID == nil
                    Button(noAlbumTitle, systemImage: "rectangle.stack.badge.minus") {
                        choose(nil)
                    }
                    .disabled(noAlbumIsDisabled)
                    .opacity(noAlbumIsDisabled ? 0.45 : 1)
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
                        .disabled(disablesCurrentChoice && isCurrent)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                .quietRows()
            }
            .labelStyle(QuietSettingsLabelStyle())
            .listStyle(.insetGrouped)
            .quietFormStyle()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .alert("New album", isPresented: $showsNewAlbum) {
                TextField("Album name", text: $newAlbumName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createNewAlbum() }
            } message: {
                Text("Albums organize encrypted media without making extra copies.")
            }
            .alert("QuietFrame", isPresented: messageIsPresented) {
                Button("OK", role: .cancel) { userMessage = nil }
            } message: {
                Text(userMessage ?? VaultError.persistenceFailure.localizedDescription)
            }
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { userMessage != nil }, set: { if !$0 { userMessage = nil } })
    }

    private func createNewAlbum() {
        guard let createAlbum else { return }
        do {
            let albumID = try createAlbum(newAlbumName)
            choose(albumID)
        } catch {
            userMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
    }
}
