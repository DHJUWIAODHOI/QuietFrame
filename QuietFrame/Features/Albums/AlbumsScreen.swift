import SwiftData
import SwiftUI
import UIKit

private let albumRowLeadingSide: CGFloat = 56

struct AlbumsScreen: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VaultAlbum.position) private var albums: [VaultAlbum]
    @Query(filter: #Predicate<VaultMedia> { $0.trashedAt == nil }) private var activeMedia: [VaultMedia]
    @Query private var settingsRecords: [AppSettings]

    @State private var showsNewAlbum = false
    @State private var newAlbumName = ""
    @State private var renameAlbum: VaultAlbum?
    @State private var renameValue = ""
    @State private var deleteAlbum: VaultAlbum?
    @State private var showsAlbumReorder = false
    @State private var userMessage: String?

    private var sortedAlbums: [VaultAlbum] {
        switch settingsRecords.first?.albumSort ?? .modifiedDate {
        case .manual:
            albums
        case .name:
            albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .creationDate:
            albums.sorted { $0.createdAt > $1.createdAt }
        case .modifiedDate:
            albums.sorted { $0.modifiedAt > $1.modifiedAt }
        }
    }

    var body: some View {
        List {
            collectionsSection
            userAlbumsSection
        }
        .listStyle(.insetGrouped)
        .quietFormStyle()
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort albums", selection: albumSortBinding) {
                        ForEach(AlbumSortOption.allCases) { option in
                            Text(sortTitle(option)).tag(option)
                        }
                    }
                } label: {
                    Label("Sort albums", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    showsAlbumReorder = true
                } label: {
                    Label("Reorder albums", systemImage: "line.3.horizontal")
                }
                .disabled(albums.count < 2)
                Button {
                    newAlbumName = ""
                    showsNewAlbum = true
                } label: {
                    Label("New album", systemImage: "plus")
                }
                .accessibilityIdentifier("new-album")
            }
        }
        .alert("New album", isPresented: $showsNewAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createAlbum() }
        } message: {
            Text("Albums organize encrypted media without making extra copies.")
        }
        .alert("Rename album", isPresented: renameIsPresented) {
            TextField("Album name", text: $renameValue)
            Button("Cancel", role: .cancel) { renameAlbum = nil }
            Button("Rename") { commitRename() }
        }
        .confirmationDialog(
            deleteAlbum.map { "Delete \($0.name)?" } ?? "Delete album?",
            isPresented: deleteIsPresented,
            titleVisibility: .visible
        ) {
            Button("Delete album, keep media") {
                performDelete(mode: .keepMedia)
            }
            Button("Delete album and move media to Trash", role: .destructive) {
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
        .sheet(isPresented: $showsAlbumReorder) {
            AlbumReorderSheet(albums: sortedAlbums) { ids in
                try dependencies.albumService.reorderAlbums(ids: ids)
                HapticFeedback.success()
            }
        }
    }

    private var collectionsSection: some View {
        Section {
            collectionRow(.allMedia, count: activeMedia.count)
            collectionRow(.recentlyAdded, count: recentCount)
            collectionRow(.favorites, count: activeMedia.lazy.filter(\.isFavorite).count)
        } header: {
            Text("Collections")
                .font(QuietFrameTheme.sectionTitleFont)
                .foregroundStyle(QuietFrameTheme.ink)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
        }
        .quietRows()
    }

    private var userAlbumsSection: some View {
        Section {
            if sortedAlbums.isEmpty {
                Button {
                    showsNewAlbum = true
                } label: {
                    AlbumsListRow(
                        title: "Create an album to organize private media",
                        titleColor: QuietFrameTheme.accent
                    ) {
                        AlbumsGlyph(systemName: "rectangle.stack.badge.plus", tint: QuietFrameTheme.accent)
                    }
                }
            } else {
                ForEach(sortedAlbums) { album in
                    albumRow(album)
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: QuietFrameTheme.compactSpacing) {
                Text("Your albums")
                    .font(QuietFrameTheme.sectionTitleFont)
                    .foregroundStyle(QuietFrameTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(sortedAlbums.count, format: .number)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .padding(.horizontal, QuietFrameTheme.compactSpacing)
                    .padding(.vertical, QuietFrameTheme.compactSpacing / 2)
                    .background(QuietFrameTheme.elevated, in: Capsule())
                    .fixedSize()
                    .accessibilityLabel("\(sortedAlbums.count) albums")
            }
            .textCase(nil)
        } footer: {
            Text("Albums organize encrypted media without making extra copies.")
                .font(.subheadline)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .quietRows()
    }

    private func albumRow(_ album: VaultAlbum) -> some View {
        let detail = itemCountText(album.activeMediaCount)
        return NavigationLink {
            GalleryBrowser(
                title: album.name,
                initialQuery: GalleryQuery(collection: nil, albumID: album.id)
            )
        } label: {
            AlbumsListRow(title: album.name, detail: detail, detailIsTrailing: true) {
                AlbumCover(album: album, thumbnailService: dependencies.thumbnailService)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(album.name), \(detail)")
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                startRename(album)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteAlbum = album
            }
        }
        .accessibilityAction(named: "Rename") {
            startRename(album)
        }
        .accessibilityAction(named: "Delete") {
            deleteAlbum = album
        }
    }

    private func collectionRow(_ collection: VaultCollection, count: Int) -> some View {
        let detail = collection == .recentlyAdded
            ? "\(itemCountText(count)) from the last 30 days"
            : itemCountText(count)
        return NavigationLink {
            GalleryBrowser(
                title: collection.title,
                initialQuery: GalleryQuery(collection: collection)
            )
        } label: {
            AlbumsListRow(title: collection.title, detail: detail) {
                AlbumsGlyph(systemName: collectionSymbol(collection))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(collection.title), \(detail)")
        }
    }

    private func collectionSymbol(_ collection: VaultCollection) -> String {
        switch collection {
        case .allMedia: "photo.on.rectangle"
        case .recentlyAdded: "clock"
        case .favorites: "heart"
        }
    }

    private func sortTitle(_ option: AlbumSortOption) -> String {
        switch option {
        case .manual: "Manual"
        case .name: "Name"
        case .creationDate: "Date created"
        case .modifiedDate: "Last modified"
        }
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

    private func startRename(_ album: VaultAlbum) {
        renameAlbum = album
        renameValue = album.name
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

private func itemCountText(_ count: Int) -> String {
    "\(count.formatted()) item\(count == 1 ? "" : "s")"
}

private struct AlbumReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [VaultAlbum]
    @State private var userMessage: String?
    let save: ([UUID]) throws -> Void

    init(albums: [VaultAlbum], save: @escaping ([UUID]) throws -> Void) {
        _albums = State(initialValue: albums)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(albums) { album in
                        Label(album.name, systemImage: "rectangle.stack")
                            .labelStyle(QuietSettingsLabelStyle())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .onMove { albums.move(fromOffsets: $0, toOffset: $1) }
                }
                .quietRows()
            }
            .listStyle(.insetGrouped)
            .quietFormStyle()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        do {
                            try save(albums.map(\.id))
                            dismiss()
                        } catch {
                            userMessage = (error as? VaultError)?.localizedDescription
                                ?? VaultError.persistenceFailure.localizedDescription
                        }
                    }
                }
            }
            .alert("QuietFrame", isPresented: Binding(
                get: { userMessage != nil },
                set: { if !$0 { userMessage = nil } }
            )) {
                Button("OK", role: .cancel) { userMessage = nil }
            } message: {
                Text(userMessage ?? "The album order could not be saved.")
            }
        }
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
    }
}

private struct AlbumsListRow<Leading: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let detail: String?
    let detailIsTrailing: Bool
    let titleColor: Color
    let leading: Leading

    init(
        title: String,
        detail: String? = nil,
        detailIsTrailing: Bool = false,
        titleColor: Color = QuietFrameTheme.ink,
        @ViewBuilder leading: () -> Leading
    ) {
        self.title = title
        self.detail = detail
        self.detailIsTrailing = detailIsTrailing
        self.titleColor = titleColor
        self.leading = leading()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
                leading
                    .frame(width: albumRowLeadingSide, height: albumRowLeadingSide)
                stackedText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, QuietFrameTheme.compactSpacing / 2)
        } else {
            HStack(spacing: 14) {
                leading
                    .frame(width: 40, height: 40)
                if detailIsTrailing, let detail {
                    titleText
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    detailText(detail)
                        .layoutPriority(1)
                } else {
                    stackedText
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: QuietFrameTheme.controlHeight)
        }
    }

    private var stackedText: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleText
            if let detail {
                detailText(detail)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private var titleText: some View {
        Text(title)
            .font(.body.weight(.medium))
            .foregroundStyle(titleColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(QuietFrameTheme.quietInk)
    }
}

private struct AlbumsGlyph: View {
    let systemName: String
    var tint = QuietFrameTheme.ink

    var body: some View {
        RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous)
            .fill(QuietFrameTheme.inset)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

private struct AlbumCover: View {
    let album: VaultAlbum
    let thumbnailService: ThumbnailService

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private func pixelSize(for cover: VaultMedia) -> Int {
        ThumbnailService.pixelSize(
            fillingSquareOf: albumRowLeadingSide,
            scale: displayScale,
            mediaPixelSize: CGSize(width: cover.pixelWidth, height: cover.pixelHeight)
        )
    }

    private var displayedImage: UIImage? {
        if let image { return image }
        guard let cover else { return nil }
        return thumbnailService.cachedImage(for: cover, pixelSize: pixelSize(for: cover))
    }

    private var cover: VaultMedia? {
        if let coverMediaID = album.coverMediaID,
           let selected = album.media.first(where: { $0.id == coverMediaID && !$0.isTrashed }) {
            return selected
        }
        return album.media.first(where: { !$0.isTrashed })
    }

    private var coverKey: String {
        guard let cover else { return "" }
        return "\(cover.id.uuidString)-\(cover.thumbnailIdentifier ?? "")"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous)
            .fill(QuietFrameTheme.inset)
            .overlay {
                if let image = displayedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: cover?.mediaType.symbolName ?? "rectangle.stack")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous))
            .task(id: "\(coverKey)#\(thumbnailService.generation)") {
                guard let cover else {
                    image = nil
                    return
                }
                let loaded = await thumbnailService.image(for: cover, pixelSize: pixelSize(for: cover))
                if !Task.isCancelled { image = loaded }
            }
            .accessibilityHidden(true)
    }
}
