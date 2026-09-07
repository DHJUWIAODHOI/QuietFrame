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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: dynamicTypeSize.isAccessibilitySize ? 280 : minimumCellWidth,
                maximum: dynamicTypeSize.isAccessibilitySize ? QuietFrameTheme.readableWidth : minimumCellWidth * 1.45
            ),
            spacing: QuietFrameTheme.compactSpacing / 2,
            alignment: .top
        )]
    }

    var body: some View {
        Group {
            if viewModel.items.isEmpty, viewModel.isLoading {
                loadingGrid
            } else if viewModel.items.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: QuietFrameTheme.compactSpacing / 2) {
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
                    .padding(QuietFrameTheme.compactSpacing / 2)

                    if viewModel.isLoading {
                        ProgressView()
                            .padding()
                            .accessibilityLabel("Loading more media")
                    }
                }
                .refreshable { await viewModel.loadInitial() }
            }
        }
        .background(QuietFrameTheme.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.items.count)
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: QuietFrameTheme.compactSpacing / 2) {
                ForEach(0..<18, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous)
                        .fill(QuietFrameTheme.inset)
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
            .padding(QuietFrameTheme.compactSpacing / 2)
        }
        .overlay { ProgressView().accessibilityLabel("Loading vault") }
    }

    @ViewBuilder
    private var emptyView: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if let emptyActionTitle, let emptyAction {
                        EmptyVaultView(
                            title: emptyTitle,
                            message: viewModel.errorMessage ?? emptyDescription,
                            actionTitle: emptyActionTitle,
                            action: emptyAction
                        )
                    } else {
                        VStack(spacing: QuietFrameTheme.contentSpacing) {
                            ContentUnavailableView(
                                emptyTitle,
                                systemImage: "photo.on.rectangle.angled",
                                description: Text(viewModel.errorMessage ?? emptyDescription)
                            )
                            if viewModel.errorMessage != nil {
                                Button("Try Again") { Task { await viewModel.loadInitial() } }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                            }
                        }
                        .padding(QuietFrameTheme.pagePadding)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
