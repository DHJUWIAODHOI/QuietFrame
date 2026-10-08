import SwiftData
import SwiftUI

func mediaPageState(pageIndex: Int, selectedIndex: Int) -> (isActive: Bool, shouldPrepare: Bool) {
    (pageIndex == selectedIndex, abs(pageIndex - selectedIndex) <= 1)
}

/// Page indexes to prepare, most urgent first: the selected page, then the next and previous pages.
func mediaPreparationOrder(selectedIndex: Int, count: Int) -> [Int] {
    guard (0..<count).contains(selectedIndex) else { return [] }
    return [selectedIndex, selectedIndex + 1, selectedIndex - 1].filter { (0..<count).contains($0) }
}

/// The new controls visibility after a page's video starts or stops playing, or nil when nothing changes.
func viewerControlsVisibility(
    afterPlaybackChange isPlaying: Bool,
    isSelectedPage: Bool,
    controlsAreVisible: Bool
) -> Bool? {
    guard isSelectedPage, controlsAreVisible == isPlaying else { return nil }
    return !isPlaying
}

struct MediaViewer: View {
    let items: [VaultMedia]
    let dependencies: AppDependencies

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query(sort: \VaultAlbum.position) private var albums: [VaultAlbum]
    @State private var selectedMediaID: UUID
    @State private var photoLoader: ViewerPhotoLoader
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
        _photoLoader = State(initialValue: ViewerPhotoLoader(storage: dependencies.secureStorage))
    }

    private var selectedMedia: VaultMedia? {
        items.first { $0.id == selectedMediaID }
    }

    private var selectedIndex: Int {
        items.firstIndex { $0.id == selectedMediaID } ?? items.startIndex
    }

    private var photoRequests: [ViewerPhotoRequest] {
        mediaPreparationOrder(selectedIndex: selectedIndex, count: items.count)
            .map { items[$0] }
            .filter { $0.mediaType == .photo }
            .map { ViewerPhotoRequest(media: $0) }
    }

    var body: some View {
        viewerContent
        .statusBarHidden(!controlsAreVisible)
        .persistentSystemOverlays(controlsAreVisible ? .automatic : .hidden)
        .onAppear { photoLoader.prepare(photoRequests) }
        .onDisappear { photoLoader.releaseAll() }
        .onChange(of: photoRequests) { _, requests in
            photoLoader.prepare(requests)
        }
        .onChange(of: selectedMediaID) { _, _ in
            selectedPhotoIsZoomed = false
            controlsAreVisible = true
        }
        .sheet(item: $informationMedia) { media in
            MediaInfoView(media: media)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $movingMedia) { media in
            AlbumDestinationPicker(albums: albums, currentAlbumID: media.album?.id) { albumID in
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
        let selectedIndex = self.selectedIndex
        return TabView(selection: $selectedMediaID) {
            ForEach(Array(items.enumerated()), id: \.element.id) { pageIndex, media in
                let pageState = mediaPageState(pageIndex: pageIndex, selectedIndex: selectedIndex)
                SecureMediaPage(
                    media: media,
                    isActive: pageState.isActive,
                    shouldPrepare: pageState.shouldPrepare,
                    storage: dependencies.secureStorage,
                    photoLoader: photoLoader,
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
            HStack(spacing: QuietFrameTheme.compactSpacing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .frame(minWidth: QuietFrameTheme.controlHeight, minHeight: QuietFrameTheme.controlHeight)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close viewer")
                Spacer()
                if let selectedMedia {
                    Text(selectedMedia.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.8), radius: 4)
                }
                Spacer()
                Button {
                    informationMedia = selectedMedia
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.medium))
                        .frame(minWidth: QuietFrameTheme.controlHeight, minHeight: QuietFrameTheme.controlHeight)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Media information")
            }
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.top, QuietFrameTheme.compactSpacing)

            Spacer()

            if let selectedMedia {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: QuietFrameTheme.compactSpacing),
                        count: dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact
                            ? 2 : (selectedMedia.isTrashed ? 3 : 4)
                    ),
                    spacing: QuietFrameTheme.compactSpacing
                ) {
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
                        viewerActionLabel(title: "Export", symbol: "square.and.arrow.up")
                    }
                    .disabled(isWorking)
                    if !selectedMedia.isTrashed {
                        viewerButton(title: "Trash", symbol: "trash") {
                            confirmsTrash = true
                        }
                    }
                }
                .padding(QuietFrameTheme.compactSpacing)
                .frame(maxWidth: QuietFrameTheme.readableWidth)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius))
                .padding(.horizontal, QuietFrameTheme.pagePadding)
                .padding(.bottom, QuietFrameTheme.contentSpacing)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
    }

    private func viewerButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            viewerActionLabel(title: title, symbol: symbol)
        }
    }

    private func viewerActionLabel(title: String, symbol: String) -> some View {
        VStack(spacing: QuietFrameTheme.compactSpacing) {
            Image(systemName: symbol)
                .font(.title3)
            Text(title)
                .font(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, QuietFrameTheme.compactSpacing)
        .frame(minWidth: QuietFrameTheme.controlHeight, maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
        .contentShape(Rectangle())
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
        guard let visibility = viewerControlsVisibility(
            afterPlaybackChange: isPlaying,
            isSelectedPage: mediaID == selectedMediaID,
            controlsAreVisible: controlsAreVisible
        ) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            controlsAreVisible = visibility
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
                shareLease = try await dependencies.mediaExportService.prepareForSharing(mediaIDs: [media.id])
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
                try await dependencies.mediaExportService.saveToPhotos(mediaIDs: [media.id])
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
