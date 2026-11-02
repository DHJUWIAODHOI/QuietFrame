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
    var tileVisibility: MediaTileVisibility?
    let open: (VaultMedia) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale

    @State private var gridWidth: CGFloat = 0

    // Fits the default thumbnail size to three columns on iPhone inside the page margins.
    private static let tileWidthScale: CGFloat = 0.85
    private static let contentSpace = "gallery-grid-content"
    private static let prefetchDistance = 12

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous)
    }

    private var minimumTileWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 280 : minimumCellWidth * Self.tileWidthScale
    }

    private var maximumTileWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? QuietFrameTheme.readableWidth : minimumCellWidth * 1.45
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: minimumTileWidth, maximum: maximumTileWidth),
            spacing: QuietFrameTheme.gridSpacing,
            alignment: .top
        )]
    }

    private var tileWidth: CGFloat? {
        guard gridWidth > 0 else { return nil }
        return adaptiveGridTileWidth(
            availableWidth: gridWidth - QuietFrameTheme.pagePadding * 2,
            minimum: minimumTileWidth,
            maximum: maximumTileWidth,
            spacing: QuietFrameTheme.gridSpacing
        )
    }

    var body: some View {
        Group {
            if viewModel.items.isEmpty, viewModel.isLoading || !viewModel.hasLoaded {
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
                                    tileWidth: tileWidth,
                                    isSelected: viewModel.selectedIDs.contains(media.id),
                                    selectionMode: viewModel.isSelecting
                                )
                            }
                            .buttonStyle(.plain)
                            .modifier(HiddenWhileViewed(mediaID: media.id, visibility: tileVisibility))
                            .background { tileFrameReporter(for: media.id) }
                            .onAppear { prefetchThumbnails(around: media) }
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
                    .background { contentOriginReporter }
                    .coordinateSpace(name: Self.contentSpace)
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
        .background { widthReporter }
        .background(QuietFrameTheme.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.items.count)
    }

    /// A tile already on screen re-runs its paging task when a refresh makes it the last loaded item.
    private func loadsNextPage(from media: VaultMedia) -> Bool {
        viewModel.hasMore && media.id == viewModel.itemIDs.last
    }

    private func prefetchThumbnails(around media: VaultMedia) {
        guard let tileWidth, let index = viewModel.index(of: media.id) else { return }
        let items = viewModel.items
        let lower = max(index - Self.prefetchDistance, 0)
        let upper = min(index + Self.prefetchDistance, items.count - 1)
        guard lower <= upper else { return }
        let scale = displayScale
        thumbnailService.prefetch(Array(items[lower...upper])) { item in
            ThumbnailService.pixelSize(
                fillingSquareOf: tileWidth,
                scale: scale,
                mediaPixelSize: CGSize(width: item.pixelWidth, height: item.pixelHeight)
            )
        }
    }

    /// Frames in the grid's own space change only when the layout does, not on every scrolled frame.
    @ViewBuilder
    private func tileFrameReporter(for mediaID: UUID) -> some View {
        if let tileFrames {
            GeometryReader { proxy in
                let tileFrame = proxy.frame(in: .named(Self.contentSpace))
                Color.clear
                    .onAppear { tileFrames.set(tileFrame, for: mediaID) }
                    .onChange(of: tileFrame) { _, newFrame in tileFrames.set(newFrame, for: mediaID) }
                    .onDisappear { tileFrames.remove(mediaID) }
            }
        }
    }

    @ViewBuilder
    private var contentOriginReporter: some View {
        if let tileFrames {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                Color.clear
                    .onAppear { tileFrames.contentOrigin = origin }
                    .onChange(of: origin) { _, newOrigin in tileFrames.contentOrigin = newOrigin }
            }
        }
    }

    private var widthReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { gridWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newWidth in gridWidth = newWidth }
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

private struct HiddenWhileViewed: ViewModifier {
    let mediaID: UUID
    let visibility: MediaTileVisibility?

    func body(content: Content) -> some View {
        content.opacity(visibility?.hiddenMediaID == mediaID ? 0 : 1)
    }
}

func adaptiveGridTileWidth(availableWidth: CGFloat, minimum: CGFloat, maximum: CGFloat, spacing: CGFloat) -> CGFloat {
    guard availableWidth > 0, minimum > 0 else { return max(minimum, 1) }
    let columnCount = max(1, Int(((availableWidth + spacing) / (minimum + spacing)).rounded(.down)))
    let width = (availableWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
    return min(max(width, 1), max(maximum, minimum))
}
