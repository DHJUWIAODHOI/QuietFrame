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
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRecords: [AppSettings]
    @Query(sort: \VaultAlbum.position) private var albums: [VaultAlbum]

    let dependencies: AppDependencies
    let title: String
    let initialQuery: GalleryQuery
    let allowsImport: Bool

    @State private var galleryViewModel: GalleryViewModel
    @State private var importViewModel: ImportViewModel
    @State private var showsPicker = false
    @State private var allowsOriginalDeletionForImport = false
    @State private var pickerOutput: PhotoLibraryPickerOutput?
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
        .task {
            if initialQuery.albumID != nil {
                galleryViewModel.query.dateSortDirection = settingsRecords.first?.albumMediaDateSortDirection
                    ?? .newestFirst
            }
            await galleryViewModel.loadInitial()
        }
        .sheet(isPresented: $showsPicker, onDismiss: finishImportSelection) {
            PhotoLibraryPicker(
                allowsOriginalDeletion: allowsOriginalDeletionForImport
            ) { output in
                pickerOutput = output
                showsPicker = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showsImportPreview, onDismiss: {
            importViewModel.cleanupIfIdle()
            Task { await galleryViewModel.loadInitial() }
        }) {
            ImportPreviewView(viewModel: importViewModel) {
                showsImportPreview = false
            }
        }
        .sheet(isPresented: $showsAlbumDestinations) {
            AlbumDestinationPicker(
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
            Button(allowsOriginalDeletionForImport ? "Continue with Limited Access" : "Continue Without Automatic Deletion") {
                showsPicker = true
            }
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
                    if initialQuery.albumID != nil,
                       galleryViewModel.query.sort == .importedAt
                        || galleryViewModel.query.sort == .createdAt {
                        Divider()
                        Picker("Sort Order", selection: dateSortDirectionBinding) {
                            ForEach(MediaDateSortDirection.allCases) { direction in
                                Text(direction.title).tag(direction)
                            }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: QuietFrameTheme.contentSpacing) {
                    selectionCount.fixedSize()
                    Spacer(minLength: QuietFrameTheme.contentSpacing)
                    selectionActions
                }
                .padding(.horizontal, QuietFrameTheme.pagePadding)

                VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
                    selectionCount
                        .padding(.horizontal, QuietFrameTheme.pagePadding)
                    ScrollView(.horizontal) {
                        selectionActions
                            .padding(.horizontal, QuietFrameTheme.pagePadding)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
            }
            .padding(.vertical, QuietFrameTheme.compactSpacing)
            .background(QuietFrameTheme.elevated)
            .overlay(alignment: .top) {
                Rectangle().fill(QuietFrameTheme.separator).frame(height: 0.5)
            }
        }
    }

    private var selectionCount: some View {
        Text("\(galleryViewModel.selectedIDs.count) Selected")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectionActions: some View {
        HStack(spacing: QuietFrameTheme.compactSpacing) {
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
        .font(.subheadline.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: QuietFrameTheme.compactCornerRadius))
        .controlSize(.large)
        .fixedSize()
    }

    private var filterBinding: Binding<MediaFilter> {
        Binding(get: { galleryViewModel.query.filter }, set: { galleryViewModel.updateFilter($0) })
    }

    private var sortBinding: Binding<MediaSortOption> {
        Binding(get: { galleryViewModel.query.sort }, set: { galleryViewModel.updateSort($0) })
    }

    private var dateSortDirectionBinding: Binding<MediaDateSortDirection> {
        Binding(
            get: { galleryViewModel.query.dateSortDirection },
            set: { direction in
                guard let settings = settingsRecords.first else { return }
                settings.albumMediaDateSortDirection = direction
                do {
                    try modelContext.save()
                    Task { await galleryViewModel.updateDateSortDirection(direction) }
                } catch {
                    modelContext.rollback()
                    actionMessage = VaultError.persistenceFailure.localizedDescription
                }
            }
        )
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
            allowsOriginalDeletionForImport = access != .denied
            switch access {
            case .full:
                showsPicker = true
            case .limited:
                photosAccessWarningMessage = "With Limited Photos Access, QuietFrame can offer deletion only for selected items it can access and revalidate safely. Other originals must be deleted manually."
                showsPhotosAccessWarning = true
            case .denied:
                photosAccessWarningMessage = "Photos access is disabled. QuietFrame can still import through the system picker, but automatic deletion remains off because QuietFrame cannot inspect and revalidate the selected originals through PhotoKit. Enable Full Access in Settings to use deletion prompts."
                showsPhotosAccessWarning = true
            }
        }
    }

    private func finishImportSelection() {
        guard let output = pickerOutput else { return }
        pickerOutput = nil
        guard !output.selections.isEmpty
                || output.pickerFailureCount > 0 else { return }
        importViewModel.prepare(
            selections: output.selections,
            pickerFailureCount: output.pickerFailureCount
        )
        showsImportPreview = true
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
