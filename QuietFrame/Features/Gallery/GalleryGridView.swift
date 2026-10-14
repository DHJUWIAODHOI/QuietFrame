import SwiftUI

struct GalleryGridView: View {
    @Bindable var viewModel: GalleryViewModel
    let thumbnailService: ThumbnailService
    let minimumCellWidth: CGFloat
    let emptyTitle: String
    let emptyDescription: String
    var emptyActionTitle: String?
    var emptyAction: (() -> Void)?
    var tileFrames: MediaTileFrames?
    var hiddenMediaID: UUID?
    let open: (VaultMedia) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Fits the default thumbnail size to three columns on iPhone inside the page margins.
    private static let tileWidthScale: CGFloat = 0.85

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous)
    }

    private var columns: [GridItem] {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        return [GridItem(
            .adaptive(
                minimum: isAccessibilitySize ? 280 : minimumCellWidth * Self.tileWidthScale,
                maximum: isAccessibilitySize ? QuietFrameTheme.readableWidth : minimumCellWidth * 1.45
            ),
            spacing: QuietFrameTheme.gridSpacing,
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
                    LazyVGrid(columns: columns, spacing: QuietFrameTheme.gridSpacing) {
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
                            .opacity(media.id == hiddenMediaID ? 0 : 1)
                            .background { tileFrameReporter(for: media.id) }
                            .contentShape(.contextMenuPreview, tileShape)
                            .onLongPressGesture(minimumDuration: 0.35) {
                                viewModel.beginSelection(with: media.id)
                            }
                            .contextMenu {
                                Button(media.isFavorite ? "Remove favorite" : "Favorite", systemImage: media.isFavorite ? "heart.slash" : "heart") {
                                    viewModel.setFavorite(mediaID: media.id, isFavorite: !media.isFavorite)
                                }
                                Button("Select", systemImage: "checkmark.circle") {
                                    viewModel.beginSelection(with: media.id)
                                }
                            }
                            .accessibilityAction(named: media.isFavorite ? "Remove favorite" : "Favorite") {
                                viewModel.setFavorite(mediaID: media.id, isFavorite: !media.isFavorite)
                            }
                            .accessibilityAction(named: "Select") {
                                viewModel.beginSelection(with: media.id)
                            }
                            .task(id: loadsNextPage(from: media)) {
                                await viewModel.loadNextIfNeeded(currentItem: media)
                            }
                        }
                    }
                    .padding(.horizontal, QuietFrameTheme.pagePadding)
                    .padding(.vertical, QuietFrameTheme.compactSpacing)

                    if viewModel.isLoading {
                        ProgressView()
                            .tint(QuietFrameTheme.quietInk)
                            .padding()
                            .accessibilityLabel("Loading more media")
                    }
                }
                .refreshable { await viewModel.loadInitial() }
                .background { viewportReporter }
            }
        }
        .background(QuietFrameTheme.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.items.count)
    }

    /// A tile already on screen re-runs its paging task when a refresh makes it the last loaded item.
    private func loadsNextPage(from media: VaultMedia) -> Bool {
        viewModel.hasMore && media.id == viewModel.items.last?.id
    }

    @ViewBuilder
    private func tileFrameReporter(for mediaID: UUID) -> some View {
        if let tileFrames {
            GeometryReader { proxy in
                let tileFrame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { tileFrames.set(tileFrame, for: mediaID) }
                    .onChange(of: tileFrame) { _, newFrame in tileFrames.set(newFrame, for: mediaID) }
                    .onDisappear { tileFrames.remove(mediaID) }
            }
        }
    }

    @ViewBuilder
    private var viewportReporter: some View {
        if let tileFrames {
            GeometryReader { proxy in
                let viewport = unobscuredViewport(
                    frame: proxy.frame(in: .global),
                    topInset: proxy.safeAreaInsets.top,
                    bottomInset: proxy.safeAreaInsets.bottom
                )
                Color.clear
                    .onAppear { tileFrames.viewport = viewport }
                    .onChange(of: viewport) { _, newViewport in tileFrames.viewport = newViewport }
            }
        }
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: QuietFrameTheme.gridSpacing) {
                ForEach(0..<18, id: \.self) { _ in
                    tileShape
                        .fill(QuietFrameTheme.elevated)
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.vertical, QuietFrameTheme.compactSpacing)
        }
        .overlay {
            ProgressView()
                .tint(QuietFrameTheme.quietInk)
                .accessibilityLabel("Loading vault")
        }
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
                        VStack(spacing: QuietFrameTheme.sectionSpacing) {
                            QuietIntroduction(
                                title: emptyTitle,
                                message: viewModel.errorMessage ?? emptyDescription,
                                systemImage: "photo.on.rectangle.angled"
                            )
                            if viewModel.errorMessage != nil {
                                Button("Try again") { Task { await viewModel.loadInitial() } }
                                    .buttonStyle(.apertureSecondary)
                            }
                        }
                        .frame(maxWidth: QuietFrameTheme.readableWidth)
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
