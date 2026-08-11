import SwiftData
import SwiftUI

struct MediaPageState: Equatable {
    let isActive: Bool
    let shouldPrepare: Bool
}

func mediaPageState(pageIndex: Int, selectedIndex: Int) -> MediaPageState {
    MediaPageState(
        isActive: pageIndex == selectedIndex,
        shouldPrepare: abs(pageIndex - selectedIndex) <= 1
    )
}

struct MediaViewer: View {
    let items: [VaultMedia]
    let dependencies: AppDependencies

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \VaultAlbum.position) private var albums: [VaultAlbum]
    @State private var selectedMediaID: UUID
    @State private var controlsAreVisible = true
    @State private var selectedPhotoIsZoomed = false
    @State private var informationMedia: VaultMedia?
    @State private var movingMedia: VaultMedia?
    @State private var shareLease: MediaExportLease?
    @State private var confirmsTrash = false
    @State private var confirmsPermanentDeletion = false
    @State private var isWorking = false
    @State private var userMessage: String?

    init(items: [VaultMedia], initialMediaID: UUID, dependencies: AppDependencies) {
        self.items = items
        self.dependencies = dependencies
        _selectedMediaID = State(initialValue: initialMediaID)
    }

    private var selectedMedia: VaultMedia? {
        items.first { $0.id == selectedMediaID }
    }

    var body: some View {
        viewerContent
        .statusBarHidden(!controlsAreVisible)
        .persistentSystemOverlays(controlsAreVisible ? .automatic : .hidden)
        .onChange(of: selectedMediaID) { _, _ in
            selectedPhotoIsZoomed = false
            controlsAreVisible = true
        }
        .sheet(item: $informationMedia) { media in
            MediaInfoView(media: media)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $movingMedia) { media in
            ViewerAlbumPicker(albums: albums, currentAlbumID: media.album?.id) { albumID in
                move(media: media, to: albumID)
                movingMedia = nil
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareLease, onDismiss: {
            shareLease?.cleanup()
            shareLease = nil
        }) { lease in
            ShareSheet(urls: lease.urls) {
                lease.cleanup()
                shareLease = nil
            }
        }
        .confirmationDialog(
            "Move this item to Trash?",
            isPresented: $confirmsTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashSelectedMedia() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The encrypted item can be restored until it expires.")
        }
        .confirmationDialog(
            "Permanently delete this item?",
            isPresented: $confirmsPermanentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { permanentlyDeleteSelectedMedia() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the encrypted file from this device and cannot be undone.")
        }
        .alert("QuietFrame", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { userMessage = nil }
        } message: {
            Text(userMessage ?? "The action could not be completed.")
        }
        .accessibilityIdentifier("media-viewer")
        .accessibilityAction(named: "Close Viewer") { dismiss() }
    }

    private var viewerContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            mediaPager

            if controlsAreVisible {
                controls
                    .transition(.opacity)
            }
        }
    }

    private var mediaPager: some View {
        let selectedIndex = items.firstIndex { $0.id == selectedMediaID } ?? items.startIndex
        return TabView(selection: $selectedMediaID) {
            ForEach(Array(items.enumerated()), id: \.element.id) { pageIndex, media in
                let pageState = mediaPageState(pageIndex: pageIndex, selectedIndex: selectedIndex)
                SecureMediaPage(
                    media: media,
                    isActive: pageState.isActive,
                    shouldPrepare: pageState.shouldPrepare,
                    storage: dependencies.secureStorage,
                    onPhotoTap: togglePhotoControls,
                    onPhotoZoomChanged: { updatePhotoZoom($0, mediaID: media.id) },
                    onVideoPlaybackChanged: { updateVideoPlayback($0, mediaID: media.id) }
                )
                .tag(media.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .simultaneousGesture(dismissGesture)
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .accessibilityLabel("Close viewer")
                Spacer()
                if let selectedMedia {
                    Text(selectedMedia.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    informationMedia = selectedMedia
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .accessibilityLabel("Media information")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()

            if let selectedMedia {
                HStack(spacing: 12) {
                    if selectedMedia.isTrashed {
                        viewerButton(title: "Restore", symbol: "arrow.uturn.backward") {
                            restoreSelectedMedia()
                        }
                        viewerButton(title: "Delete", symbol: "trash.slash") {
                            confirmsPermanentDeletion = true
                        }
                    } else {
                        viewerButton(
                            title: selectedMedia.isFavorite ? "Unfavorite" : "Favorite",
                            symbol: selectedMedia.isFavorite ? "heart.fill" : "heart"
                        ) {
                            favorite(selectedMedia)
                        }
                        viewerButton(title: "Move", symbol: "folder") {
                            movingMedia = selectedMedia
                        }
                    }
                    Menu {
                        Button("Share", systemImage: "square.and.arrow.up") { share(selectedMedia) }
                        Button("Save to Photos", systemImage: "photo.badge.arrow.down") { saveToPhotos(selectedMedia) }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                            Text("Export")
                                .font(.caption)
                        }
                        .frame(minWidth: 64, minHeight: 44)
                    }
                    .disabled(isWorking)
                    if !selectedMedia.isTrashed {
                        viewerButton(title: "Trash", symbol: "trash") {
                            confirmsTrash = true
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 18)
            }
        }
        .foregroundStyle(.white)
    }

    private func viewerButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(minWidth: 64, minHeight: 44)
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { userMessage != nil }, set: { if !$0 { userMessage = nil } })
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                let translation = value.translation
                let predicted = value.predictedEndTranslation
                guard !selectedPhotoIsZoomed,
                      translation.height > 80,
                      predicted.height > 160,
                      abs(predicted.height) > abs(predicted.width) * 1.2 else { return }
                dismiss()
            }
    }

    private func togglePhotoControls() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            controlsAreVisible.toggle()
        }
    }

    private func updatePhotoZoom(_ isZoomed: Bool, mediaID: UUID) {
        guard mediaID == selectedMediaID else { return }
        selectedPhotoIsZoomed = isZoomed
    }

    private func updateVideoPlayback(_ isPlaying: Bool, mediaID: UUID) {
        guard mediaID == selectedMediaID, isPlaying else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            controlsAreVisible = false
        }
    }

    private func favorite(_ media: VaultMedia) {
        do {
            try dependencies.repository.setFavorite(mediaID: media.id, isFavorite: !media.isFavorite)
        } catch {
            userMessage = VaultError.persistenceFailure.localizedDescription
        }
    }

    private func move(media: VaultMedia, to albumID: UUID?) {
        do {
            try dependencies.albumService.moveMedia(ids: [media.id], toAlbumID: albumID)
        } catch {
            userMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
    }

    private func share(_ media: VaultMedia) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                shareLease = try await dependencies.mediaExportService.prepareForSharing(media: [media])
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.exportFailed.localizedDescription
            }
            isWorking = false
        }
    }

    private func saveToPhotos(_ media: VaultMedia) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.mediaExportService.saveToPhotos(media: [media])
                userMessage = "Saved to Photos."
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.exportFailed.localizedDescription
            }
            isWorking = false
        }
    }

    private func trashSelectedMedia() {
        guard let selectedMedia, !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.trashService.moveToTrash(ids: [selectedMedia.id])
                dismiss()
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
                isWorking = false
            }
        }
    }

    private func restoreSelectedMedia() {
        guard let selectedMedia, !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.trashService.restore(ids: [selectedMedia.id])
                dismiss()
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
                isWorking = false
            }
        }
    }

    private func permanentlyDeleteSelectedMedia() {
        guard let selectedMedia, !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.trashService.permanentlyDelete(ids: [selectedMedia.id])
                dependencies.thumbnailService.clearCache()
                dismiss()
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
                isWorking = false
            }
        }
    }
}

private struct ViewerAlbumPicker: View {
    let albums: [VaultAlbum]
    let currentAlbumID: UUID?
    let choose: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button("No Album", systemImage: "rectangle.stack.badge.minus") { choose(nil) }
                    .disabled(currentAlbumID == nil)
                ForEach(albums) { album in
                    Button {
                        choose(album.id)
                    } label: {
                        HStack {
                            Label(album.name, systemImage: "rectangle.stack")
                            Spacer()
                            if currentAlbumID == album.id { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(currentAlbumID == album.id)
                }
            }
            .navigationTitle("Move to Album")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
