import SwiftUI

struct GalleryGridView: View {
    @Bindable var viewModel: GalleryViewModel
    let thumbnailService: ThumbnailService
    let minimumCellWidth: CGFloat
    let emptyTitle: String
    let emptyDescription: String
    var emptyActionTitle: String?
    var emptyAction: (() -> Void)?
    let open: (VaultMedia) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumCellWidth, maximum: minimumCellWidth * 1.45), spacing: 3)]
    }

    var body: some View {
        Group {
            if viewModel.items.isEmpty, viewModel.isLoading {
                loadingGrid
            } else if viewModel.items.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(viewModel.items) { media in
                            Button {
                                if viewModel.isSelecting {
                                    viewModel.toggleSelection(media.id)
                                } else {
                                    open(media)
                                }
                            } label: {
                                MediaThumbnailView(
                                    media: media,
                                    thumbnailService: thumbnailService,
                                    isSelected: viewModel.selectedIDs.contains(media.id),
                                    selectionMode: viewModel.isSelecting
                                )
                            }
                            .buttonStyle(.plain)
                            .onLongPressGesture(minimumDuration: 0.35) {
                                viewModel.beginSelection(with: media.id)
                            }
                            .contextMenu {
                                Button(media.isFavorite ? "Remove Favorite" : "Favorite", systemImage: media.isFavorite ? "heart.slash" : "heart") {
                                    viewModel.setFavorite(mediaID: media.id, isFavorite: !media.isFavorite)
                                }
                                Button("Select", systemImage: "checkmark.circle") {
                                    viewModel.beginSelection(with: media.id)
                                }
                            }
                            .accessibilityAction(named: media.isFavorite ? "Remove Favorite" : "Favorite") {
                                viewModel.setFavorite(mediaID: media.id, isFavorite: !media.isFavorite)
                            }
                            .accessibilityAction(named: "Select") {
                                viewModel.beginSelection(with: media.id)
                            }
                            .task {
                                await viewModel.loadNextIfNeeded(currentItem: media)
                            }
                        }
                    }
                    .padding(.horizontal, 3)

                    if viewModel.isLoading {
                        ProgressView()
                            .padding()
                            .accessibilityLabel("Loading more media")
                    }
                }
                .refreshable { await viewModel.loadInitial() }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.items.count)
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<18, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
            .padding(3)
        }
        .overlay { ProgressView().accessibilityLabel("Loading vault") }
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "photo.on.rectangle.angled",
                description: Text(viewModel.errorMessage ?? emptyDescription)
            )
            if let emptyActionTitle, let emptyAction {
                Button(emptyActionTitle, action: emptyAction)
                    .buttonStyle(.borderedProminent)
            } else if viewModel.errorMessage != nil {
                Button("Try Again") { Task { await viewModel.loadInitial() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
