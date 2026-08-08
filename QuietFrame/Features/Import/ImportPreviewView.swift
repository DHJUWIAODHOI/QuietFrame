import SwiftUI

struct ImportPreviewView: View {
    @Bindable var viewModel: ImportViewModel
    let dismiss: () -> Void

    @State private var confirmsOriginalDeletion = false

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 10)
    ]

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
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing your selection")
                .font(.headline)
            Text("Reading metadata and creating private previews without changing the originals.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing selected media")
    }

    private var importingView: some View {
        VStack(spacing: 22) {
            ProgressView(value: viewModel.progress.overallFraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .accessibilityLabel("Import progress")
                .accessibilityValue(Text(viewModel.progress.overallFraction, format: .percent))
            Text("Encrypting \(min(viewModel.progress.completedItems + 1, viewModel.progress.totalItems)) of \(viewModel.progress.totalItems)")
                .font(.headline.monospacedDigit())
            Text("You can cancel safely. A partially encrypted item is removed before the import stops.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(QuietFrameTheme.pagePadding)
    }

    private var previewGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review \(viewModel.candidates.count) item\(viewModel.candidates.count == 1 ? "" : "s") before encryption.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(viewModel.candidates) { candidate in
                        ImportPreviewCell(candidate: candidate) {
                            viewModel.removeCandidate(id: candidate.id)
                        }
                    }
                }

                if let message = viewModel.userMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Warning: \(message)")
                }
            }
            .padding(QuietFrameTheme.pagePadding)
        }
    }

    private func resultView(_ summary: ImportSummary) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: summary.importedCount > 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 58))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(summary.importedCount > 0 ? Color.accentColor : .orange)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(summary.wasCancelled ? "Import Cancelled" : "Import Complete")
                        .font(.title.bold())
                    Text(resultDescription(summary))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    resultMetric("Imported", value: summary.importedCount)
                    resultMetric("Duplicates", value: summary.duplicateCount)
                    resultMetric("Failed", value: summary.failedCount)
                }
                if summary.thumbnailFailureCount > 0 {
                    Label(
                        "\(summary.thumbnailFailureCount) preview\(summary.thumbnailFailureCount == 1 ? "" : "s") could not be created; the encrypted originals remain available.",
                        systemImage: "photo.badge.exclamationmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let message = viewModel.userMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(QuietFrameTheme.pagePadding)
        }
    }

    private func resultMetric(_ title: String, value: Int) -> some View {
        VStack(spacing: 5) {
            Text(value, format: .number)
                .font(.title2.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .quietCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var bottomAction: some View {
        if !viewModel.isPreparing {
            VStack(spacing: 10) {
                if let summary = viewModel.summary {
                    if summary.shouldOfferOriginalDeletion {
                        Button("Delete Imported Originals from Photos", role: .destructive) {
                            confirmsOriginalDeletion = true
                        }
                        .disabled(viewModel.isDeletingOriginals)
                    }
                    Button("Done", action: dismiss)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else if viewModel.isImporting {
                    Button("Cancel Import", role: .destructive) {
                        viewModel.cancelImport()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                } else if !viewModel.candidates.isEmpty {
                    Button {
                        viewModel.startImport()
                    } label: {
                        Label("Encrypt and Import", systemImage: "lock.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("begin-import")
                }
            }
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.vertical, 12)
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
            Group {
                if let image = candidate.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: candidate.source.metadata.mediaType.symbolName)
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(height: 132)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .padding(6)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Remove \(candidate.source.metadata.originalFilename ?? "item")")

            if candidate.source.metadata.mediaType == .video,
               let duration = candidate.source.metadata.duration {
                Text(formattedDuration(duration))
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.64), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
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
