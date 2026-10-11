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
    @State private var tileFrames: MediaTileFrames
    @State private var hiddenMediaID: UUID?
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
        _tileFrames = State(initialValue: MediaTileFrames())
    }

    private var thumbnailWidth: CGFloat {
        CGFloat(settingsRecords.first?.thumbnailSize.minimumWidth ?? ThumbnailSize.comfortable.minimumWidth)
    }

    var body: some View {
        GalleryGridView(
            viewModel: galleryViewModel,
            thumbnailService: dependencies.thumbnailService,
            minimumCellWidth: thumbnailWidth,
            emptyTitle: allowsImport ? "Your vault is ready" : "No media here",
            emptyDescription: allowsImport
                ? "Import photos and videos to protect them on this device."
                : "Items matching this collection will appear here.",
            emptyActionTitle: allowsImport ? "Choose media" : nil,
            emptyAction: allowsImport ? beginImportSelection : nil,
            tileFrames: tileFrames,
            hiddenMediaID: hiddenMediaID
        ) { media in
            presentViewer(for: media)
        }
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
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
            .presentationBackground(QuietFrameTheme.elevated)
            .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $viewerRequest, onDismiss: {
            Task {
                await galleryViewModel.loadInitial()
                if viewerRequest == nil { hiddenMediaID = nil }
            }
        }) { request in
            MediaViewer(
                items: galleryViewModel.items,
                initialMediaID: request.mediaID,
                dependencies: dependencies,
                tileFrames: tileFrames,
                onCurrentMediaChange: { hiddenMediaID = $0 }
            )
            .presentationBackground(Color.clear)
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
            "Photos access needed",
            isPresented: $showsPhotosAccessWarning,
            titleVisibility: .visible
        ) {
            Button("Open Settings") { openSystemSettings() }
            Button(allowsOriginalDeletionForImport ? "Continue with limited access" : "Continue without automatic deletion") {
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
        if galleryViewModel.isSelecting {
            ToolbarItem(placement: .principal) {
                selectionCount
                    .font(.headline)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if galleryViewModel.isSelecting {
                Button("Cancel") { galleryViewModel.endSelection() }
            } else {
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
                        Picker("Sort order", selection: dateSortDirectionBinding) {
                            ForEach(MediaDateSortDirection.allCases) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                    }
                } label: {
                    Label("Filter and sort", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button("Select") {
                    galleryViewModel.beginSelection()
                }
                if allowsImport {
                    Button("Import", systemImage: "plus") { beginImportSelection() }
                        .accessibilityIdentifier("import-media")
                }
            }
        }
    }

    private var showsFilterChips: Bool {
        !galleryViewModel.items.isEmpty
            || galleryViewModel.query.filter != .all
            || !galleryViewModel.query.searchText.isEmpty
    }

    @ViewBuilder
    private var filterBar: some View {
        if showsFilterChips {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: QuietFrameTheme.compactSpacing) {
                    ForEach(MediaFilter.allCases) { filter in
                        let isSelected = galleryViewModel.query.filter == filter
                        Button(filter.title) { selectFilter(filter) }
                            .buttonStyle(GalleryFilterChipStyle(isSelected: isSelected))
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }

                Menu {
                    Picker("Filter", selection: filterBinding) {
                        ForEach(MediaFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    Text("Filter: \(galleryViewModel.query.filter.title)")
                }
                .buttonStyle(GalleryFilterChipStyle(isSelected: false))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.top, QuietFrameTheme.compactSpacing / 2)
            .padding(.bottom, QuietFrameTheme.compactSpacing)
            .background(QuietFrameTheme.background)
            .disabled(galleryViewModel.isSelecting)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter")
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if galleryViewModel.isSelecting {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    selectionActions
                }

                VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
                    selectionCount
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, QuietFrameTheme.compactSpacing)
                        .padding(.top, QuietFrameTheme.compactSpacing)
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            selectionActions
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
            }
            .buttonStyle(GallerySelectionActionStyle())
            .padding(.horizontal, QuietFrameTheme.compactSpacing)
            .padding(.vertical, QuietFrameTheme.compactSpacing / 2)
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .background(
                QuietFrameTheme.elevated,
                in: RoundedRectangle(cornerRadius: QuietFrameTheme.sheetCornerRadius, style: .continuous)
            )
            .padding(.horizontal, QuietFrameTheme.contentSpacing)
            .padding(.bottom, QuietFrameTheme.compactSpacing)
        }
    }

    private var selectionCount: some View {
        Text("\(galleryViewModel.selectedIDs.count) selected")
            .monospacedDigit()
            .foregroundStyle(QuietFrameTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var selectionActions: some View {
        Button {
            selectedItems.forEach {
                galleryViewModel.setFavorite(mediaID: $0.id, isFavorite: true)
            }
        } label: {
            GallerySelectionActionLabel(title: "Favorite", systemImage: "heart")
        }
        .disabled(galleryViewModel.selectedIDs.isEmpty)

        Button {
            showsAlbumDestinations = true
        } label: {
            GallerySelectionActionLabel(title: "Move", systemImage: "folder")
        }
        .disabled(galleryViewModel.selectedIDs.isEmpty)

        Menu {
            Button("Share", systemImage: "square.and.arrow.up") { shareSelection() }
            Button("Save to Photos", systemImage: "photo.badge.arrow.down") { saveSelectionToPhotos() }
        } label: {
            GallerySelectionActionLabel(title: "Export", systemImage: "square.and.arrow.up")
        }
        .disabled(galleryViewModel.selectedIDs.isEmpty || isExporting)
        .accessibilityHint("Share or save to Photos")

        Button(role: .destructive) {
            confirmsMoveToTrash = true
        } label: {
            GallerySelectionActionLabel(title: "Trash", systemImage: "trash", isDestructive: true)
        }
        .disabled(galleryViewModel.selectedIDs.isEmpty)

        if let albumID = initialQuery.albumID, galleryViewModel.selectedIDs.count == 1 {
            Button {
                setCover(albumID: albumID)
            } label: {
                GallerySelectionActionLabel(title: "Cover", systemImage: "photo")
            }
            .accessibilityHint("Sets the selected item as the album cover")
        }
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

    private func presentViewer(for media: VaultMedia) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewerRequest = MediaViewerRequest(mediaID: media.id)
        }
    }

    private func selectFilter(_ filter: MediaFilter) {
        guard filterBinding.wrappedValue != filter else { return }
        filterBinding.wrappedValue = filter
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
        let mediaIDs = selectedItems.map(\.id)
        guard !mediaIDs.isEmpty, !isExporting else { return }
        isExporting = true
        Task {
            do {
                shareLease = try await dependencies.mediaExportService.prepareForSharing(mediaIDs: mediaIDs)
            } catch {
                actionMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.exportFailed.localizedDescription
            }
            isExporting = false
        }
    }

    private func saveSelectionToPhotos() {
        let mediaIDs = selectedItems.map(\.id)
        guard !mediaIDs.isEmpty, !isExporting else { return }
        isExporting = true
        Task {
            do {
                try await dependencies.mediaExportService.saveToPhotos(mediaIDs: mediaIDs)
                actionMessage = "Saved \(mediaIDs.count) item\(mediaIDs.count == 1 ? "" : "s") to Photos."
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

private struct GallerySelectionActionLabel: View {
    let title: String
    let systemImage: String
    var isDestructive = false

    @ScaledMetric(relativeTo: .title3) private var iconHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(height: iconHeight)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(isDestructive ? QuietFrameTheme.destructive : QuietFrameTheme.ink)
        .padding(.horizontal, QuietFrameTheme.compactSpacing)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
    }
}

private struct GallerySelectionActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

private struct GalleryFilterChipStyle: ButtonStyle {
    let isSelected: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(isSelected ? .semibold : .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(isSelected ? QuietFrameTheme.background : QuietFrameTheme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: QuietFrameTheme.controlHeight)
            .background(isSelected ? QuietFrameTheme.accent : QuietFrameTheme.elevated, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }
}

struct MediaViewerRequest: Identifiable {
    let mediaID: UUID
    var id: UUID { mediaID }
}
