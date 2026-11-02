import SwiftData
import SwiftUI

struct TrashScreen: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        TrashScreenContent(dependencies: dependencies)
    }
}

private struct TrashScreenContent: View {
    @Query private var settingsRecords: [AppSettings]

    let dependencies: AppDependencies
    @State private var viewModel: GalleryViewModel
    @State private var viewerRequest: MediaViewerRequest?
    @State private var tileFrames: MediaTileFrames
    @State private var tileVisibility = MediaTileVisibility()
    @State private var confirmsPermanentDeletion = false
    @State private var confirmsEmptyTrash = false
    @State private var userMessage: String?
    @State private var isWorking = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: GalleryViewModel(
            repository: dependencies.repository,
            query: GalleryQuery(
                collection: nil,
                sort: .importedAt,
                includesTrash: true
            )
        ))
        _tileFrames = State(initialValue: MediaTileFrames())
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.items.isEmpty {
                retentionBanner
            }
            GalleryGridView(
                viewModel: viewModel,
                thumbnailService: dependencies.thumbnailService,
                minimumCellWidth: CGFloat(settingsRecords.first?.thumbnailSize.minimumWidth ?? 120),
                emptyTitle: "Trash is empty",
                emptyDescription: "Deleted media remains encrypted here until it expires.",
                tileFrames: tileFrames,
                tileVisibility: tileVisibility,
                open: { media in presentViewer(for: media) }
            )
        }
        .background(QuietFrameTheme.background)
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: searchBinding, prompt: "Search Trash")
        .toolbar { trashToolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .task {
            do {
                if try await dependencies.trashService.purgeExpiredItems() > 0 {
                    dependencies.thumbnailService.clearCache()
                }
            } catch is CancellationError {
                return
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
            }
            await viewModel.refreshLoadedItems()
        }
        .fullScreenCover(item: $viewerRequest, onDismiss: {
            Task {
                await viewModel.refreshLoadedItems()
                if viewerRequest == nil { tileVisibility.hiddenMediaID = nil }
            }
        }) { request in
            MediaViewer(
                items: viewModel.items,
                initialMediaID: request.mediaID,
                dependencies: dependencies,
                tileFrames: tileFrames,
                onCurrentMediaChange: { tileVisibility.hiddenMediaID = $0 }
            )
            .presentationBackground(Color.clear)
        }
        .confirmationDialog(
            "Permanently delete selected media?",
            isPresented: $confirmsPermanentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) { permanentlyDeleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes encrypted files from this device and cannot be undone.")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $confirmsEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every encrypted item in Trash will be permanently removed.")
        }
        .alert("QuietFrame", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { userMessage = nil }
        } message: {
            Text(userMessage ?? "The Trash action could not be completed.")
        }
    }

    private var retentionBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "clock")
                .font(.body)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .accessibilityHidden(true)
            Text("Items are permanently deleted after \(settingsRecords.first?.trashRetentionDays ?? 30) days.")
                .font(.subheadline)
                .foregroundStyle(QuietFrameTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, QuietFrameTheme.contentSpacing)
        .quietCard()
        .padding(.horizontal, QuietFrameTheme.pagePadding)
        .padding(.vertical, QuietFrameTheme.compactSpacing)
    }

    @ToolbarContentBuilder
    private var trashToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if viewModel.isSelecting {
                Button("Cancel") { viewModel.endSelection() }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !viewModel.isSelecting {
                Menu {
                    Picker("Filter", selection: filterBinding) {
                        ForEach(MediaFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    Picker("Sort", selection: sortBinding) {
                        ForEach(MediaSortOption.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                } label: {
                    Label("Filter and sort", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button("Select", systemImage: "checkmark.circle") { viewModel.beginSelection() }
                    .disabled(viewModel.items.isEmpty)
                Button("Empty Trash", systemImage: "trash.slash", role: .destructive) {
                    confirmsEmptyTrash = true
                }
                .disabled(viewModel.items.isEmpty || isWorking)
                .tint(QuietFrameTheme.destructive)
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if viewModel.isSelecting {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: QuietFrameTheme.compactSpacing / 2) {
                    selectionCount
                        .fixedSize()
                        .padding(.leading, 12)
                    Spacer(minLength: QuietFrameTheme.compactSpacing)
                    HStack(spacing: QuietFrameTheme.compactSpacing / 2) {
                        restoreButton
                        deleteButton
                    }
                    .fixedSize()
                }

                VStack(spacing: QuietFrameTheme.compactSpacing / 2) {
                    selectionCount
                        .padding(.top, QuietFrameTheme.compactSpacing)
                    HStack(spacing: QuietFrameTheme.compactSpacing / 2) {
                        restoreButton
                            .frame(maxWidth: .infinity)
                        deleteButton
                            .frame(maxWidth: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing / 2) {
                    selectionCount
                        .padding(.top, QuietFrameTheme.compactSpacing)
                        .padding(.horizontal, 12)
                    ScrollView(.horizontal) {
                        HStack(spacing: QuietFrameTheme.compactSpacing / 2) {
                            restoreButton
                            deleteButton
                        }
                        .fixedSize()
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
            }
            .labelStyle(TrashSelectionLabelStyle())
            .buttonStyle(TrashSelectionButtonStyle())
            .padding(.horizontal, QuietFrameTheme.compactSpacing)
            .padding(.vertical, QuietFrameTheme.compactSpacing / 2)
            .frame(minHeight: 64)
            .background(
                QuietFrameTheme.elevated,
                in: RoundedRectangle(cornerRadius: QuietFrameTheme.sheetCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: QuietFrameTheme.sheetCornerRadius, style: .continuous)
                    .strokeBorder(QuietFrameTheme.separator, lineWidth: 1)
            }
            .padding(.horizontal, QuietFrameTheme.contentSpacing)
            .padding(.bottom, QuietFrameTheme.compactSpacing)
        }
    }

    private var selectionCount: some View {
        Text("\(viewModel.selectedIDs.count) selected")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(QuietFrameTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var restoreButton: some View {
        Button("Restore", systemImage: "arrow.uturn.backward") { restoreSelection() }
            .disabled(viewModel.selectedIDs.isEmpty || isWorking)
    }

    private var deleteButton: some View {
        Button("Delete permanently", systemImage: "trash", role: .destructive) {
            confirmsPermanentDeletion = true
        }
        .disabled(viewModel.selectedIDs.isEmpty || isWorking)
    }

    private var searchBinding: Binding<String> {
        Binding(get: { viewModel.query.searchText }, set: { viewModel.updateSearch($0) })
    }

    private var filterBinding: Binding<MediaFilter> {
        Binding(get: { viewModel.query.filter }, set: { viewModel.updateFilter($0) })
    }

    private var sortBinding: Binding<MediaSortOption> {
        Binding(get: { viewModel.query.sort }, set: { viewModel.updateSort($0) })
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { userMessage != nil }, set: { if !$0 { userMessage = nil } })
    }

    private func presentViewer(for media: VaultMedia) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewerRequest = MediaViewerRequest(mediaID: media.id)
        }
    }

    private func restoreSelection() {
        let ids = viewModel.selectedIDs
        perform {
            try await dependencies.trashService.restore(ids: ids)
        }
    }

    private func permanentlyDeleteSelection() {
        let ids = viewModel.selectedIDs
        let thumbnailIdentifiers = viewModel.items.filter { ids.contains($0.id) }.compactMap(\.thumbnailIdentifier)
        perform(evicting: .thumbnails(thumbnailIdentifiers)) {
            try await dependencies.trashService.permanentlyDelete(ids: ids)
        }
    }

    private func emptyTrash() {
        perform(evicting: .allThumbnails) {
            try await dependencies.trashService.emptyTrash()
        }
    }

    /// Thumbnails of permanently deleted media leave the memory cache with them.
    private enum ThumbnailEviction {
        case none
        case thumbnails([String])
        case allThumbnails
    }

    private func evictThumbnails(_ eviction: ThumbnailEviction) {
        switch eviction {
        case .none:
            break
        case .thumbnails(let identifiers):
            dependencies.thumbnailService.removeImages(forThumbnailIdentifiers: identifiers)
        case .allThumbnails:
            dependencies.thumbnailService.clearCache()
        }
    }

    private func perform(evicting eviction: ThumbnailEviction = .none, _ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await operation()
                viewModel.endSelection()
                evictThumbnails(eviction)
                await viewModel.refreshLoadedItems()
                HapticFeedback.success()
            } catch {
                // A delete can fail after removing some items, so their thumbnails leave the cache either way.
                evictThumbnails(eviction)
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
            }
            isWorking = false
        }
    }
}

private struct TrashSelectionLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: 8) {
                configuration.icon
                    .font(.title3)
                configuration.title
                    .font(.caption.weight(.medium))
            }
        } else {
            VStack(spacing: 4) {
                configuration.icon
                    .font(.title3)
                    .frame(minHeight: 24)
                configuration.title
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TrashSelectionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == ButtonRole.destructive ? QuietFrameTheme.destructive : QuietFrameTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 72, minHeight: 56)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}
