import SwiftData
import SwiftUI

struct ImportPreviewView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \VaultAlbum.position) private var albums: [VaultAlbum]
    @Bindable var viewModel: ImportViewModel
    let dismiss: () -> Void

    @State private var confirmsOriginalDeletion = false
    @State private var destinationAlbumID: UUID?

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: dynamicTypeSize.isAccessibilitySize ? 160 : 104,
                maximum: dynamicTypeSize.isAccessibilitySize ? 240 : 160
            ),
            spacing: QuietFrameTheme.gridSpacing
        )]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if viewModel.isPreparing {
                    preparingView
                } else if viewModel.isImporting {
                    importingView
                } else if let summary = viewModel.summary {
                    resultView(summary)
                } else if viewModel.candidates.isEmpty {
                    emptyView
                } else {
                    previewGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ground)
        .safeAreaInset(edge: .bottom) { bottomAction }
        .confirmationDialog(
            "Delete originals from Photos?",
            isPresented: $confirmsOriginalDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete from Photos", role: .destructive) {
                viewModel.deleteImportedOriginals()
            }
            Button("Keep originals", role: .cancel) {}
        } message: {
            Text("iOS will ask for permission. Deleted items may remain in the Photos app's Recently Deleted album. QuietFrame never deletes originals automatically. Your vault copies are not in iCloud backup. If you delete the originals, the vault holds the only copy.")
        }
        .interactiveDismissDisabled(viewModel.isImporting)
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
        .presentationDragIndicator(viewModel.isImporting ? .hidden : .visible)
        .onChange(of: viewModel.summary) { _, summary in
            guard summary?.shouldOfferOriginalDeletion == true else { return }
            Task { @MainActor in
                await Task.yield()
                confirmsOriginalDeletion = true
            }
        }
        .onDisappear { viewModel.cleanupIfIdle() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: QuietFrameTheme.contentSpacing) {
            if let headerTitle, !dynamicTypeSize.isAccessibilitySize {
                reviewTitle(headerTitle)
            }
            Spacer(minLength: 0)
            if !viewModel.isImporting {
                Button {
                    if viewModel.isPreparing { viewModel.cancelPreparation() }
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(QuietFrameTheme.ink)
                        .frame(width: QuietFrameTheme.controlHeight, height: QuietFrameTheme.controlHeight)
                        .background(QuietFrameTheme.inset, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .frame(minHeight: QuietFrameTheme.controlHeight)
        .frame(maxWidth: QuietFrameTheme.readableWidth)
        .padding(.horizontal, QuietFrameTheme.pagePadding)
        .padding(.top, 20)
        .frame(maxWidth: .infinity)
    }

    private func reviewTitle(_ title: String) -> some View {
        Text(title)
            .font(QuietFrameTheme.titleFont)
            .foregroundStyle(QuietFrameTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var preparingView: some View {
        ScrollView {
            VStack(spacing: QuietFrameTheme.sectionSpacing) {
                ProgressView()
                    .controlSize(.large)
                    .tint(QuietFrameTheme.accent)
                VStack(spacing: QuietFrameTheme.compactSpacing) {
                    Text("Preparing your selection")
                        .font(QuietFrameTheme.titleFont)
                        .foregroundStyle(QuietFrameTheme.ink)
                    Text("Reading metadata and creating private previews without changing the originals.")
                        .font(.body)
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(QuietFrameTheme.pagePadding)
            .padding(.vertical, QuietFrameTheme.sectionSpacing)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preparing selected media")
        }
    }

    private var emptyView: some View {
        ScrollView {
            VStack(spacing: QuietFrameTheme.contentSpacing) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 26, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .frame(width: 64, height: 64)
                    .background(
                        QuietFrameTheme.background,
                        in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(spacing: QuietFrameTheme.compactSpacing) {
                    Text("Nothing to import")
                        .font(QuietFrameTheme.titleFont)
                        .foregroundStyle(QuietFrameTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(viewModel.userMessage ?? "Choose supported photos or videos.")
                        .font(.body)
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(QuietFrameTheme.pagePadding)
            .padding(.vertical, QuietFrameTheme.sectionSpacing)
            .frame(maxWidth: .infinity)
        }
    }

    private var importingView: some View {
        ScrollView {
            VStack(spacing: QuietFrameTheme.sectionSpacing) {
                ApertureIris(
                    closure: CGFloat(irisFraction),
                    filledBlades: Int((irisFraction * 6).rounded(.down)),
                    size: dynamicTypeSize.isAccessibilitySize ? 112 : 152
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: irisFraction)
                .accessibilityHidden(true)
                VStack(spacing: QuietFrameTheme.contentSpacing) {
                    Text("Encrypting \(min(viewModel.progress.completedItems + 1, viewModel.progress.totalItems)) of \(viewModel.progress.totalItems)")
                        .font(QuietFrameTheme.titleFont.monospacedDigit())
                        .foregroundStyle(QuietFrameTheme.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    ProgressView(value: viewModel.progress.overallFraction)
                        .progressViewStyle(.linear)
                        .tint(QuietFrameTheme.accent)
                        .accessibilityLabel("Import progress")
                        .accessibilityValue(Text(viewModel.progress.overallFraction, format: .percent))
                }
                Text("You can cancel safely. A partially encrypted item is removed before the import stops.")
                    .font(.body)
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(QuietFrameTheme.pagePadding)
            .padding(.vertical, QuietFrameTheme.contentSpacing)
            .frame(maxWidth: .infinity)
        }
    }

    private var previewGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
                if dynamicTypeSize.isAccessibilitySize {
                    if let headerTitle {
                        reviewTitle(headerTitle)
                    }
                    destinationRow
                }

                LazyVGrid(columns: columns, spacing: QuietFrameTheme.gridSpacing) {
                    ForEach(viewModel.candidates) { candidate in
                        ImportPreviewCell(candidate: candidate) {
                            viewModel.removeCandidate(id: candidate.id)
                        }
                    }
                }

                Text("QuietFrame read these items without changing the originals. Nothing is encrypted until you choose Encrypt and import.")
                    .font(.subheadline)
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = viewModel.userMessage {
                    ImportNotice(
                        message: message,
                        systemImage: "exclamationmark.triangle",
                        isEmphasized: true,
                        surface: QuietFrameTheme.background
                    )
                    .accessibilityLabel("Warning: \(message)")
                }
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.top, QuietFrameTheme.contentSpacing)
            .padding(.bottom, QuietFrameTheme.pagePadding)
            .frame(maxWidth: .infinity)
        }
    }

    private func resultView(_ summary: ImportSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.wasCancelled ? "Import cancelled" : "Import complete")
                        .quietScreenTitle()
                    Text(resultDescription(summary))
                        .font(.body)
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

                VStack(spacing: 0) {
                    resultMetric("Imported", value: summary.importedCount)
                    metricDivider
                    resultMetric("Duplicates skipped", detail: "Already in the vault", value: summary.duplicateCount)
                    metricDivider
                    resultMetric("Failed", value: summary.failedCount)
                }
                .quietCard()

                if summary.thumbnailFailureCount > 0 {
                    ImportNotice(
                        message: "\(summary.thumbnailFailureCount) preview\(summary.thumbnailFailureCount == 1 ? "" : "s") could not be created; the encrypted originals remain available.",
                        systemImage: "photo.badge.exclamationmark",
                        surface: QuietFrameTheme.elevated
                    )
                }
                if summary.shouldOfferOriginalDeletion {
                    ImportNotice(
                        message: "Your vault copies are not in iCloud backup. If you delete the originals, the vault holds the only copy.",
                        systemImage: "exclamationmark.shield",
                        isEmphasized: true,
                        surface: QuietFrameTheme.elevated
                    )
                }
                if let message = viewModel.userMessage {
                    ImportNotice(message: message, surface: QuietFrameTheme.elevated)
                }
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.top, QuietFrameTheme.compactSpacing)
            .padding(.bottom, QuietFrameTheme.pagePadding)
            .frame(maxWidth: .infinity)
        }
    }

    private func resultMetric(_ title: String, detail: String? = nil, value: Int) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: QuietFrameTheme.compactSpacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: QuietFrameTheme.contentSpacing))

        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(QuietFrameTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value, format: .number)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(QuietFrameTheme.ink)
        }
        .padding(.horizontal, QuietFrameTheme.contentSpacing)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    private var metricDivider: some View {
        Divider()
            .overlay(QuietFrameTheme.separator)
            .padding(.leading, QuietFrameTheme.contentSpacing)
    }

    @ViewBuilder
    private var bottomAction: some View {
        if !viewModel.isPreparing {
            VStack(spacing: 12) {
                if let summary = viewModel.summary {
                    Button(action: dismiss) {
                        Text("Done")
                    }
                    .buttonStyle(.aperturePrimary)
                    if summary.shouldOfferOriginalDeletion {
                        Button(role: .destructive) {
                            confirmsOriginalDeletion = true
                        } label: {
                            Text("Delete imported originals from Photos")
                        }
                        .buttonStyle(.apertureDestructive)
                        .disabled(viewModel.isDeletingOriginals)
                    }
                } else if viewModel.isImporting {
                    Button("Cancel import", role: .destructive) {
                        viewModel.cancelImport()
                    }
                    .buttonStyle(.apertureSecondary)
                } else if !viewModel.candidates.isEmpty {
                    if !dynamicTypeSize.isAccessibilitySize {
                        destinationRow
                    }
                    Button {
                        viewModel.startImport(albumID: destinationAlbumID)
                    } label: {
                        Text("Encrypt and import")
                    }
                    .buttonStyle(.aperturePrimary)
                    .accessibilityIdentifier("begin-import")
                }
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, QuietFrameTheme.compactSpacing)
            .frame(maxWidth: .infinity)
            .background(ground)
        }
    }

    private var destinationRow: some View {
        Menu {
            Picker("Destination", selection: $destinationAlbumID) {
                Label(Self.vaultDestinationName, systemImage: "rectangle.stack.badge.minus")
                    .tag(Optional<UUID>.none)
                ForEach(albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .tag(Optional(album.id))
                }
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        destinationTitle
                        destinationValue
                    }
                    .padding(.vertical, QuietFrameTheme.compactSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: QuietFrameTheme.compactSpacing) {
                        destinationTitle
                            .layoutPriority(1)
                        Spacer(minLength: QuietFrameTheme.compactSpacing)
                        destinationValue
                    }
                }
            }
            .padding(.leading, QuietFrameTheme.contentSpacing)
            .padding(.trailing, 12)
            .frame(minHeight: 56)
            .background(
                QuietFrameTheme.background,
                in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous))
        }
        .accessibilityLabel("Destination")
        .accessibilityValue(destinationName)
    }

    private var destinationTitle: some View {
        Text("Destination")
            .font(.body)
            .foregroundStyle(QuietFrameTheme.quietInk)
    }

    private var destinationValue: some View {
        HStack(spacing: 4) {
            Text(destinationName)
                .font(.body.weight(.medium))
                .foregroundStyle(QuietFrameTheme.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(QuietFrameTheme.quietInk)
                .accessibilityHidden(true)
        }
    }

    private static let vaultDestinationName = "Vault (no album)"

    private var destinationName: String {
        guard let destinationAlbumID,
              let album = albums.first(where: { $0.id == destinationAlbumID }) else {
            return Self.vaultDestinationName
        }
        return album.name
    }

    private var headerTitle: String? {
        guard !viewModel.isPreparing,
              !viewModel.isImporting,
              viewModel.summary == nil,
              !viewModel.candidates.isEmpty else { return nil }
        let count = viewModel.candidates.count
        return "Review \(count) item\(count == 1 ? "" : "s")"
    }

    private var showsVaultGround: Bool {
        !viewModel.isPreparing && (viewModel.isImporting || viewModel.summary != nil)
    }

    private var ground: Color {
        showsVaultGround ? QuietFrameTheme.background : QuietFrameTheme.elevated
    }

    private var irisFraction: Double {
        let value = viewModel.progress.overallFraction
        return value.isFinite ? min(max(value, 0), 1) : 0
    }

    private func resultDescription(_ summary: ImportSummary) -> String {
        if summary.wasCancelled { return "Finished items remain protected; incomplete work was removed." }
        if summary.importedCount == 0 { return "No new media was added to your vault." }
        return "New media is encrypted and available in All Media."
    }
}

private struct ImportNotice: View {
    let message: String
    var systemImage: String?
    var isEmphasized = false
    let surface: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .foregroundStyle(isEmphasized ? QuietFrameTheme.ink : QuietFrameTheme.quietInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            surface,
            in: RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct ImportPreviewCell: View {
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 26
    let candidate: ImportPreviewCandidate
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(QuietFrameTheme.inset)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = candidate.previewImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: candidate.source.metadata.mediaType.symbolName)
                            .font(.title)
                            .foregroundStyle(QuietFrameTheme.quietInk)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if candidate.source.metadata.mediaType == .video,
                       let duration = candidate.source.metadata.duration {
                        Text(formattedDuration(duration))
                            .font(.caption.weight(.medium).monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(QuietFrameTheme.background.opacity(0.78), in: Capsule())
                            .foregroundStyle(QuietFrameTheme.ink)
                            .padding(6)
                            .accessibilityLabel("Video duration \(formattedDuration(duration))")
                    }
                }

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: badgeSize * 0.46, weight: .bold))
                    .foregroundStyle(QuietFrameTheme.ink)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(QuietFrameTheme.background.opacity(0.78), in: Circle())
                    .padding(6)
                    .frame(
                        minWidth: QuietFrameTheme.controlHeight,
                        minHeight: QuietFrameTheme.controlHeight,
                        alignment: .topTrailing
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(candidate.source.metadata.originalFilename ?? "item")")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(candidate.source.metadata.originalFilename ?? candidate.source.metadata.mediaType.title)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
