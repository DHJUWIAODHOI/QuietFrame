import SwiftData
import SwiftUI

struct AlbumsScreen: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VaultAlbum.modifiedAt, order: .reverse) private var albums: [VaultAlbum]
    @Query(filter: #Predicate<VaultMedia> { $0.trashedAt == nil }) private var activeMedia: [VaultMedia]
    @Query private var settingsRecords: [AppSettings]

    @State private var showsNewAlbum = false
    @State private var newAlbumName = ""
    @State private var renameAlbum: VaultAlbum?
    @State private var renameValue = ""
    @State private var deleteAlbum: VaultAlbum?
    @State private var userMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 240), spacing: 14)]

    private var sortedAlbums: [VaultAlbum] {
        switch settingsRecords.first?.albumSort ?? .modifiedDate {
        case .name:
            albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .creationDate:
            albums.sorted { $0.createdAt > $1.createdAt }
        case .modifiedDate:
            albums.sorted { $0.modifiedAt > $1.modifiedAt }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                smartCollections
                userAlbums
            }
            .padding(QuietFrameTheme.pagePadding)
        }
        .background(QuietFrameTheme.background)
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort Albums", selection: albumSortBinding) {
                        ForEach(AlbumSortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label("Sort Albums", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    newAlbumName = ""
                    showsNewAlbum = true
                } label: {
                    Label("New Album", systemImage: "plus")
                }
                .accessibilityIdentifier("new-album")
            }
        }
        .alert("New Album", isPresented: $showsNewAlbum) {
            TextField("Album Name", text: $newAlbumName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createAlbum() }
        } message: {
            Text("Albums organize encrypted media without making extra copies.")
        }
        .alert("Rename Album", isPresented: renameIsPresented) {
            TextField("Album Name", text: $renameValue)
            Button("Cancel", role: .cancel) { renameAlbum = nil }
            Button("Rename") { commitRename() }
        }
        .confirmationDialog(
            deleteAlbum.map { "Delete \($0.name)?" } ?? "Delete Album?",
            isPresented: deleteIsPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Album, Keep Media") {
                performDelete(mode: .keepMedia)
            }
            Button("Delete Album and Move Media to Trash", role: .destructive) {
                performDelete(mode: .moveMediaToTrash)
            }
            Button("Cancel", role: .cancel) { deleteAlbum = nil }
        } message: {
            Text("Keeping media removes only the album. Moving media to Trash can be undone until the items expire.")
        }
        .alert("QuietFrame", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { userMessage = nil }
        } message: {
            Text(userMessage ?? "The album could not be updated.")
        }
    }

    private var smartCollections: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Collections")
                .font(.title3.bold())
            LazyVGrid(columns: columns, spacing: 14) {
                smartCollectionCard(.allMedia, count: activeMedia.count)
                smartCollectionCard(.recentlyAdded, count: recentCount)
                smartCollectionCard(.favorites, count: activeMedia.lazy.filter(\.isFavorite).count)
            }
        }
    }

    private var userAlbums: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Albums")
                    .font(.title3.bold())
                Spacer()
                Text(sortedAlbums.count, format: .number)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if sortedAlbums.isEmpty {
                Button {
                    showsNewAlbum = true
                } label: {
                    Label("Create an album to organize private media", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .buttonStyle(.plain)
                .quietCard()
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(sortedAlbums) { album in
                        NavigationLink {
                            GalleryBrowser(
                                title: album.name,
                                initialQuery: GalleryQuery(collection: nil, albumID: album.id)
                            )
                        } label: {
                            AlbumCard(
                                album: album,
                                thumbnailService: dependencies.thumbnailService
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                renameAlbum = album
                                renameValue = album.name
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deleteAlbum = album
                            }
                        }
                    }
                }
            }
        }
    }

    private func smartCollectionCard(_ collection: VaultCollection, count: Int) -> some View {
        NavigationLink {
            GalleryBrowser(
                title: collection.title,
                initialQuery: GalleryQuery(collection: collection)
            )
        } label: {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: collection.symbolName)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Text(collection.title)
                    .font(.headline)
                Text(count, format: .number)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
            .padding()
            .background(QuietFrameTheme.vaultGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collection.title), \(count) items")
    }

    private var recentCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return activeMedia.lazy.filter { $0.importedAt >= cutoff }.count
    }

    private var albumSortBinding: Binding<AlbumSortOption> {
        Binding(
            get: { settingsRecords.first?.albumSort ?? .modifiedDate },
            set: { option in
                guard let settings = settingsRecords.first else { return }
                settings.albumSort = option
                do {
                    try modelContext.save()
                } catch {
                    userMessage = VaultError.persistenceFailure.localizedDescription
                }
            }
        )
    }

    private var renameIsPresented: Binding<Bool> {
        Binding(get: { renameAlbum != nil }, set: { if !$0 { renameAlbum = nil } })
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(get: { deleteAlbum != nil }, set: { if !$0 { deleteAlbum = nil } })
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { userMessage != nil }, set: { if !$0 { userMessage = nil } })
    }

    private func createAlbum() {
        do {
            _ = try dependencies.albumService.createAlbum(name: newAlbumName)
            HapticFeedback.success()
        } catch {
            userMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
    }

    private func commitRename() {
        guard let album = renameAlbum else { return }
        do {
            try dependencies.albumService.renameAlbum(id: album.id, name: renameValue)
            renameAlbum = nil
        } catch {
            userMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
    }

    private func performDelete(mode: AlbumDeletionMode) {
        guard let album = deleteAlbum else { return }
        deleteAlbum = nil
        Task {
            do {
                try await dependencies.albumService.deleteAlbum(id: album.id, mode: mode)
                HapticFeedback.success()
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.persistenceFailure.localizedDescription
            }
        }
    }
}

private struct AlbumCard: View {
    let album: VaultAlbum
    let thumbnailService: ThumbnailService

    private var cover: VaultMedia? {
        if let coverMediaID = album.coverMediaID,
           let selected = album.media.first(where: { $0.id == coverMediaID && !$0.isTrashed }) {
            return selected
        }
        return album.media.first(where: { !$0.isTrashed })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let cover {
                    MediaThumbnailView(media: cover, thumbnailService: thumbnailService)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary)
                        .aspectRatio(1.35, contentMode: .fit)
                        .overlay {
                            Image(systemName: "rectangle.stack")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1.35, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(album.name)
                .font(.headline)
                .lineLimit(1)
            Text("\(album.activeMediaCount) item\(album.activeMediaCount == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name), \(album.activeMediaCount) items")
    }
}
