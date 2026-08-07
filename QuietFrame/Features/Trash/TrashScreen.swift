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
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.items.isEmpty {
                Text("Items are permanently deleted after \(settingsRecords.first?.trashRetentionDays ?? 30) days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            GalleryGridView(
                viewModel: viewModel,
                thumbnailService: dependencies.thumbnailService,
                minimumCellWidth: CGFloat(settingsRecords.first?.thumbnailSize.minimumWidth ?? 120),
                emptyTitle: "Trash Is Empty",
                emptyDescription: "Deleted media remains encrypted here until it expires.",
                open: { media in viewerRequest = MediaViewerRequest(mediaID: media.id) }
            )
        }
        .navigationTitle("Trash")
        .searchable(text: searchBinding, prompt: "Search Trash")
        .toolbar { trashToolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .task {
            do {
                _ = try await dependencies.trashService.purgeExpiredItems()
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
            }
            await viewModel.loadInitial()
        }
        .fullScreenCover(item: $viewerRequest, onDismiss: {
            Task { await viewModel.loadInitial() }
        }) { request in
            MediaViewer(
                items: viewModel.items,
                initialMediaID: request.mediaID,
                dependencies: dependencies
            )
        }
        .confirmationDialog(
            "Permanently delete selected media?",
            isPresented: $confirmsPermanentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { permanentlyDeleteSelection() }
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
                    Label("Filter and Sort", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button("Select", systemImage: "checkmark.circle") { viewModel.beginSelection() }
                    .disabled(viewModel.items.isEmpty)
                Button("Empty Trash", systemImage: "trash.slash", role: .destructive) {
                    confirmsEmptyTrash = true
                }
                .disabled(viewModel.items.isEmpty || isWorking)
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if viewModel.isSelecting {
            HStack {
                Text("\(viewModel.selectedIDs.count) Selected")
                    .font(.subheadline.bold().monospacedDigit())
                Spacer()
                Button("Restore", systemImage: "arrow.uturn.backward") { restoreSelection() }
                    .disabled(viewModel.selectedIDs.isEmpty || isWorking)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmsPermanentDeletion = true
                }
                .disabled(viewModel.selectedIDs.isEmpty || isWorking)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(.bar)
        }
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

    private func restoreSelection() {
        let ids = viewModel.selectedIDs
        perform {
            try await dependencies.trashService.restore(ids: ids)
        }
    }

    private func permanentlyDeleteSelection() {
        let ids = viewModel.selectedIDs
        perform {
            try await dependencies.trashService.permanentlyDelete(ids: ids)
        }
    }

    private func emptyTrash() {
        perform {
            try await dependencies.trashService.emptyTrash()
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await operation()
                viewModel.endSelection()
                dependencies.thumbnailService.clearCache()
                await viewModel.loadInitial()
                HapticFeedback.success()
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
            }
            isWorking = false
        }
    }
}
