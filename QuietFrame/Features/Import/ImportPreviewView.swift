import SwiftData
import SwiftUI

struct ImportPreviewView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            spacing: QuietFrameTheme.compactSpacing
        )]
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isPreparing {
                    preparingView
                } else if viewModel.isImporting {
                    importingView
                } else if let summary = viewModel.summary {
                    resultView(summary)
                } else if viewModel.candidates.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Import",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(viewModel.userMessage ?? "Choose supported photos or videos.")
                    )
                } else {
                    previewGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(QuietFrameTheme.background)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { bottomAction }
            .confirmationDialog(
                "Delete originals from Photos?",
                isPresented: $confirmsOriginalDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete from Photos", role: .destructive) {
                    viewModel.deleteImportedOriginals()
                }
                Button("Keep Originals", role: .cancel) {}
            } message: {
                Text("iOS will ask for permission. Deleted items may remain in the Photos app's Recently Deleted album. QuietFrame never deletes originals automatically.")
            }
            .interactiveDismissDisabled(viewModel.isImporting)
        }
        .onChange(of: viewModel.summary) { _, summary in
            guard summary?.shouldOfferOriginalDeletion == true else { return }
            Task { @MainActor in
                await Task.yield()
                confirmsOriginalDeletion = true
            }
        }
        .onDisappear { viewModel.cleanupIfIdle() }
    }

    private var preparingView: some View {
        ScrollView {
            VStack(spacing: QuietFrameTheme.sectionSpacing) {
                ProgressView()
                    .controlSize(.large)
                    .tint(QuietFrameTheme.accent)
                VStack(spacing: QuietFrameTheme.compactSpacing) {
                    Text("Preparing your selection")
                        .font(.title2.weight(.semibold))
                    Text("Reading metadata and creating private previews without changing the originals.")
                        .font(.body)
                        .foregroundStyle(.secondary)
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

    private var importingView: some View {
        ScrollView {
            VStack(spacing: QuietFrameTheme.sectionSpacing) {
                QuietSymbol(systemName: "lock.fill")
                VStack(spacing: QuietFrameTheme.contentSpacing) {
                    Text("Encrypting \(min(viewModel.progress.completedItems + 1, viewModel.progress.totalItems)) of \(viewModel.progress.totalItems)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: viewModel.progress.overallFraction)
                        .progressViewStyle(.linear)
                        .tint(QuietFrameTheme.accent)
                        .accessibilityLabel("Import progress")
                        .accessibilityValue(Text(viewModel.progress.overallFraction, format: .percent))
                }
                .padding(QuietFrameTheme.pagePadding)
                .quietCard()
                Text("You can cancel safely. A partially encrypted item is removed before the import stops.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(QuietFrameTheme.pagePadding)
            .padding(.vertical, QuietFrameTheme.sectionSpacing)
            .frame(maxWidth: .infinity)
        }
    }

    private var previewGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
                Text("Review \(viewModel.candidates.count) item\(viewModel.candidates.count == 1 ? "" : "s") before encryption.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, spacing: QuietFrameTheme.compactSpacing) {
                    ForEach(viewModel.candidates) { candidate in
                        ImportPreviewCell(candidate: candidate) {
                            viewModel.removeCandidate(id: candidate.id)
                        }
                    }
                }

                if let message = viewModel.userMessage {
                    Label {
                        Text(message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .labelStyle(QuietSettingsLabelStyle())
                    .font(.subheadline)
                    .padding(QuietFrameTheme.contentSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quietCard()
                    .accessibilityLabel("Warning: \(message)")
                }
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(QuietFrameTheme.pagePadding)
            .frame(maxWidth: .infinity)
        }
    }

    private func resultView(_ summary: ImportSummary) -> some View {
        let metricsLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: QuietFrameTheme.compactSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: QuietFrameTheme.compactSpacing))

        return ScrollView {
            VStack(spacing: QuietFrameTheme.sectionSpacing) {
                Image(systemName: summary.importedCount > 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(summary.importedCount > 0 ? QuietFrameTheme.accent : .orange)
                    .frame(width: 64, height: 64)
                    .quietCard()
                    .accessibilityHidden(true)
                VStack(spacing: QuietFrameTheme.compactSpacing) {
                    Text(summary.wasCancelled ? "Import Cancelled" : "Import Complete")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(resultDescription(summary))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                metricsLayout {
                    resultMetric("Imported", value: summary.importedCount)
                    resultMetric("Duplicates", value: summary.duplicateCount)
                    resultMetric("Failed", value: summary.failedCount)
                }
                if summary.thumbnailFailureCount > 0 {
                    Label(
                        "\(summary.thumbnailFailureCount) preview\(summary.thumbnailFailureCount == 1 ? "" : "s") could not be created; the encrypted originals remain available.",
                        systemImage: "photo.badge.exclamationmark"
                    )
                    .labelStyle(QuietSettingsLabelStyle())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(QuietFrameTheme.contentSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quietCard()
                }
                if let message = viewModel.userMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(QuietFrameTheme.contentSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .quietCard()
                }
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(QuietFrameTheme.pagePadding)
            .frame(maxWidth: .infinity)
        }
    }

    private func resultMetric(_ title: String, value: Int) -> some View {
        VStack(spacing: QuietFrameTheme.compactSpacing) {
            Text(value, format: .number)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(QuietFrameTheme.contentSpacing)
        .frame(maxWidth: .infinity)
        .quietCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var bottomAction: some View {
        if !viewModel.isPreparing {
            VStack(spacing: QuietFrameTheme.contentSpacing) {
                if let summary = viewModel.summary {
                    if summary.shouldOfferOriginalDeletion {
                        Button(role: .destructive) {
                            confirmsOriginalDeletion = true
                        } label: {
                            Text("Delete Imported Originals from Photos")
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
                        }
                        .disabled(viewModel.isDeletingOriginals)
                    }
                    Button(action: dismiss) {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if viewModel.isImporting {
                    Button("Cancel Import", role: .destructive) {
                        viewModel.cancelImport()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                } else if !viewModel.candidates.isEmpty {
                    LabeledContent {
                        Picker("Destination", selection: $destinationAlbumID) {
                            Label("Vault / No Album", systemImage: "rectangle.stack.badge.minus")
                                .tag(Optional<UUID>.none)
                            ForEach(albums) { album in
                                Label(album.name, systemImage: "rectangle.stack")
                                    .tag(Optional(album.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } label: {
                        Label("Destination", systemImage: "folder")
                            .labelStyle(QuietSettingsLabelStyle())
                    }
                    Button {
                        viewModel.startImport(albumID: destinationAlbumID)
                    } label: {
                        Label("Encrypt and Import", systemImage: "lock.badge.plus")
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("begin-import")
                }
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.vertical, QuietFrameTheme.compactSpacing)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !viewModel.isImporting {
                Button("Close") {
                    if viewModel.isPreparing { viewModel.cancelPreparation() }
                    dismiss()
                }
            }
        }
    }

    private var navigationTitle: String {
        if viewModel.isImporting { return "Importing" }
        if viewModel.summary != nil { return "Import Summary" }
        return "Import Preview"
    }

    private func resultDescription(_ summary: ImportSummary) -> String {
        if summary.wasCancelled { return "Finished items remain protected; incomplete work was removed." }
        if summary.importedCount == 0 { return "No new media was added to your vault." }
        return "New media is encrypted and available in All Media."
    }
}

private struct ImportPreviewCell: View {
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
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous))

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .frame(minWidth: QuietFrameTheme.controlHeight, minHeight: QuietFrameTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove \(candidate.source.metadata.originalFilename ?? "item")")

            if candidate.source.metadata.mediaType == .video,
               let duration = candidate.source.metadata.duration {
                Text(formattedDuration(duration))
                    .font(.caption2.bold().monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, QuietFrameTheme.compactSpacing)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.64), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(QuietFrameTheme.compactSpacing)
                    .accessibilityLabel("Video duration \(formattedDuration(duration))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(candidate.source.metadata.originalFilename ?? candidate.source.metadata.mediaType.title)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
