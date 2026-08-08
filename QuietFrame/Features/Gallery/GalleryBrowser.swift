import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct GalleryBrowser: View {
    @Environment(AppDependencies.self) private var dependencies

    let title: String
    let initialQuery: GalleryQuery
    var allowsImport = false

    var body: some View {
        GalleryBrowserContent(
            dependencies: dependencies,
            title: title,
            initialQuery: initialQuery,
            allowsImport: allowsImport
        )
    }
}

private struct GalleryBrowserContent: View {
    @Query private var settingsRecords: [AppSettings]
    @Query(sort: \VaultAlbum.name) private var albums: [VaultAlbum]

    let dependencies: AppDependencies
    let title: String
    let initialQuery: GalleryQuery
    let allowsImport: Bool

    @State private var galleryViewModel: GalleryViewModel
    @State private var importViewModel: ImportViewModel
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsPicker = false
    @State private var showsImportPreview = false
    @State private var showsAlbumDestinations = false
    @State private var viewerRequest: MediaViewerRequest?
    @State private var shareLease: MediaExportLease?
    @State private var confirmsMoveToTrash = false
    @State private var showsPhotosAccessWarning = false
    @State private var photosAccessWarningMessage = ""
    @State private var isExporting = false
    @State private var actionMessage: String?

    init(
        dependencies: AppDependencies,
        title: String,
        initialQuery: GalleryQuery,
        allowsImport: Bool
    ) {
        self.dependencies = dependencies
        self.title = title
        self.initialQuery = initialQuery
        self.allowsImport = allowsImport
        _galleryViewModel = State(initialValue: GalleryViewModel(
            repository: dependencies.repository,
            query: initialQuery
        ))
        _importViewModel = State(initialValue: ImportViewModel(
            metadataReader: dependencies.metadataService,
            thumbnailGenerator: dependencies.thumbnailGenerator,
            importer: dependencies.mediaImportService,
            photoLibrary: dependencies.photoLibraryService
        ))
    }

    private var thumbnailWidth: CGFloat {
        CGFloat(settingsRecords.first?.thumbnailSize.minimumWidth ?? ThumbnailSize.comfortable.minimumWidth)
    }

    var body: some View {
        GalleryGridView(
            viewModel: galleryViewModel,
            thumbnailService: dependencies.thumbnailService,
            minimumCellWidth: thumbnailWidth,
            emptyTitle: allowsImport ? "Your Vault Is Ready" : "No Media Here",
            emptyDescription: allowsImport
                ? "Import photos and videos to protect them on this device."
                : "Items matching this collection will appear here.",
            emptyActionTitle: allowsImport ? "Choose Media" : nil,
            emptyAction: allowsImport ? beginImportSelection : nil
        ) { media in
            viewerRequest = MediaViewerRequest(mediaID: media.id)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: searchBinding, prompt: "Filename, album, date, or tag")
        .toolbar { galleryToolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .task { await galleryViewModel.loadInitial() }
        .photosPicker(
            isPresented: $showsPicker,
            selection: $pickerItems,
            maxSelectionCount: 250,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .onChange(of: pickerItems) { newItems in
            guard !newItems.isEmpty else { return }
            showsImportPreview = true
            importViewModel.prepare(items: newItems)
        }
        .sheet(isPresented: $showsImportPreview, onDismiss: {
            pickerItems = []
            importViewModel.cleanupIfIdle()
            Task { await galleryViewModel.loadInitial() }
        }) {
            ImportPreviewView(viewModel: importViewModel) {
                showsImportPreview = false
            }
        }
        .sheet(isPresented: $showsAlbumDestinations) {
            AlbumDestinationSheet(
                albums: albums,
                currentAlbumID: initialQuery.albumID
            ) { albumID in
                moveSelection(to: albumID)
                showsAlbumDestinations = false
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $viewerRequest, onDismiss: {
            Task { await galleryViewModel.loadInitial() }
        }) { request in
            MediaViewer(
                items: galleryViewModel.items,
                initialMediaID: request.mediaID,
                dependencies: dependencies
            )
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
            "Move selected media to Trash?",
            isPresented: $confirmsMoveToTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items remain encrypted and can be restored until the Trash retention period expires.")
        }
        .confirmationDialog(
            "Photos Access Needed",
            isPresented: $showsPhotosAccessWarning,
            titleVisibility: .visible
        ) {
            Button("Open Settings") { openSystemSettings() }
            Button("Continue Without Automatic Deletion") { showsPicker = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(photosAccessWarningMessage)
        }
        .alert("QuietFrame", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { actionMessage = nil; galleryViewModel.clearError() }
        } message: {
            Text(actionMessage ?? galleryViewModel.errorMessage ?? "The action could not be completed.")
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { galleryViewModel.query.searchText },
            set: { galleryViewModel.updateSearch($0) }
        )
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(
            get: { actionMessage != nil || galleryViewModel.errorMessage != nil },
            set: { if !$0 { actionMessage = nil; galleryViewModel.clearError() } }
        )
    }

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if galleryViewModel.isSelecting {
                Button("Cancel") { galleryViewModel.endSelection() }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !galleryViewModel.isSelecting {
                Menu {
                    Picker("Filter", selection: filterBinding) {
                        ForEach(MediaFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    Divider()
                    Picker("Sort", selection: sortBinding) {
                        ForEach(MediaSortOption.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                } label: {
                    Label("Filter and Sort", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button("Select", systemImage: "checkmark.circle") {
                    galleryViewModel.beginSelection()
                }
                if allowsImport {
                    Button("Import", systemImage: "plus") { beginImportSelection() }
                        .accessibilityIdentifier("import-media")
                }
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if galleryViewModel.isSelecting {
            HStack {
                Text("\(galleryViewModel.selectedIDs.count) Selected")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer()
                Button("Favorite", systemImage: "heart") {
                    selectedItems.forEach {
                        galleryViewModel.setFavorite(mediaID: $0.id, isFavorite: true)
                    }
                }
                .disabled(galleryViewModel.selectedIDs.isEmpty)
                Button("Move", systemImage: "folder") { showsAlbumDestinations = true }
                    .disabled(galleryViewModel.selectedIDs.isEmpty)
                Menu {
                    Button("Share", systemImage: "square.and.arrow.up") { shareSelection() }
                    Button("Save to Photos", systemImage: "photo.badge.arrow.down") { saveSelectionToPhotos() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(galleryViewModel.selectedIDs.isEmpty || isExporting)
                Button("Trash", systemImage: "trash", role: .destructive) {
                    confirmsMoveToTrash = true
                }
                .disabled(galleryViewModel.selectedIDs.isEmpty)
                if let albumID = initialQuery.albumID, galleryViewModel.selectedIDs.count == 1 {
                    Button("Cover", systemImage: "photo") { setCover(albumID: albumID) }
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(.bar)
        }
    }

    private var filterBinding: Binding<MediaFilter> {
        Binding(get: { galleryViewModel.query.filter }, set: { galleryViewModel.updateFilter($0) })
    }

    private var sortBinding: Binding<MediaSortOption> {
        Binding(get: { galleryViewModel.query.sort }, set: { galleryViewModel.updateSort($0) })
    }

    private var selectedItems: [VaultMedia] {
        galleryViewModel.items.filter { galleryViewModel.selectedIDs.contains($0.id) }
    }

    private func moveSelection(to albumID: UUID?) {
        do {
            try dependencies.albumService.moveMedia(ids: galleryViewModel.selectedIDs, toAlbumID: albumID)
            galleryViewModel.endSelection()
            Task { await galleryViewModel.loadInitial() }
        } catch {
            actionMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
    }

    private func setCover(albumID: UUID) {
        guard let mediaID = galleryViewModel.selectedIDs.first else { return }
        do {
            try dependencies.albumService.setCover(albumID: albumID, mediaID: mediaID)
            galleryViewModel.endSelection()
        } catch {
            actionMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
    }

    private func shareSelection() {
        let media = selectedItems
        guard !media.isEmpty, !isExporting else { return }
        isExporting = true
        Task {
            do {
                shareLease = try await dependencies.mediaExportService.prepareForSharing(media: media)
            } catch {
                actionMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.exportFailed.localizedDescription
            }
            isExporting = false
        }
    }

    private func saveSelectionToPhotos() {
        let media = selectedItems
        guard !media.isEmpty, !isExporting else { return }
        isExporting = true
        Task {
            do {
                try await dependencies.mediaExportService.saveToPhotos(media: media)
                actionMessage = "Saved \(media.count) item\(media.count == 1 ? "" : "s") to Photos."
            } catch {
                actionMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.exportFailed.localizedDescription
            }
            isExporting = false
        }
    }

    private func trashSelection() {
        let ids = galleryViewModel.selectedIDs
        Task {
            do {
                try await dependencies.trashService.moveToTrash(ids: ids)
                galleryViewModel.endSelection()
                await galleryViewModel.loadInitial()
            } catch {
                actionMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
            }
        }
    }

    private func beginImportSelection() {
        Task {
            let access = await dependencies.photoLibraryService.requestImportAccess()
            switch access {
            case .full:
                showsPicker = true
            case .limited:
                photosAccessWarningMessage = "QuietFrame needs Full Photos Access to identify every selected original for safe deletion after import. Choose Full Access in Settings, or continue knowing you may need to delete originals manually."
                showsPhotosAccessWarning = true
            case .denied:
                photosAccessWarningMessage = "Photos access is disabled. QuietFrame can still import through the system picker, but iOS will not provide the identifiers required to delete originals automatically. Enable Full Access in Settings to use deletion prompts."
                showsPhotosAccessWarning = true
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct MediaViewerRequest: Identifiable {
    let mediaID: UUID
    var id: UUID { mediaID }
}

private struct AlbumDestinationSheet: View {
    let albums: [VaultAlbum]
    let currentAlbumID: UUID?
    let choose: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    choose(nil)
                } label: {
                    Label("No Album", systemImage: "rectangle.stack.badge.minus")
                }
                .disabled(currentAlbumID == nil)

                ForEach(albums) { album in
                    Button {
                        choose(album.id)
                    } label: {
                        HStack {
                            Label(album.name, systemImage: "rectangle.stack")
                            Spacer()
                            if album.id == currentAlbumID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(album.id == currentAlbumID)
                }
            }
            .navigationTitle("Move to Album")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
