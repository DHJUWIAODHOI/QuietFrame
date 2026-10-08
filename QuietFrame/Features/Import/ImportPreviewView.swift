import SwiftData
import SwiftUI
import UIKit

struct ImportPreviewView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppDependencies.self) private var dependencies
    @Query(sort: \VaultAlbum.position) private var albums: [VaultAlbum]
    @Bindable var viewModel: ImportViewModel
    let dismiss: () -> Void

    @State private var confirmsOriginalDeletion = false
    @State private var destinationAlbumID: UUID?
    @State private var showsAlbumPicker = false
    @State private var assignmentAnnouncement: String?

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
        .interactiveDismissDisabled(protectsReview)
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
        .presentationDragIndicator(protectsReview ? .hidden : .visible)
        .onChange(of: viewModel.summary) { _, summary in
            guard summary?.shouldOfferOriginalDeletion == true else { return }
            Task { @MainActor in
                await Task.yield()
                confirmsOriginalDeletion = true
            }
        }
        .onChange(of: albumIDs, initial: true) { _, ids in
            viewModel.discardAlbumAssignments(notIn: Set(ids))
        }
        .sheet(isPresented: $showsAlbumPicker, onDismiss: { announceAssignment() }) { albumPicker }
        .onDisappear { viewModel.cleanupIfIdle() }
    }

    private var protectsReview: Bool {
        viewModel.isImporting || viewModel.albumAssignments.hasAssignments
    }

    private var albumPicker: some View {
        AlbumDestinationPicker(
            albums: albums,
            currentAlbumID: viewModel.albumAssignments.selectionAlbumID,
            title: "Add to album",
            noAlbumTitle: "Leave unassigned",
            disablesCurrentChoice: false,
            createAlbum: { try dependencies.albumService.createAlbum(name: $0).id }
        ) { albumID in
            assignmentAnnouncement = assignmentMessage(for: albumID)
            viewModel.assignSelection(toAlbumID: albumID)
            showsAlbumPicker = false
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
        .presentationDragIndicator(.visible)
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
                    selectionHint
                    if hasUnassignedCandidates {
                        destinationRow
                    }
                } else {
                    selectionHint
                }

                LazyVGrid(columns: columns, spacing: QuietFrameTheme.gridSpacing) {
                    ForEach(viewModel.candidates) { candidate in
                        ImportPreviewCell(
                            candidate: candidate,
                            albumName: albumName(for: candidate.id),
                            isSelected: viewModel.albumAssignments.isSelected(candidate.id),
                            selectionMode: viewModel.albumAssignments.hasSelection,
                            toggleSelection: { viewModel.toggleSelection(id: candidate.id) }
                        ) {
                            viewModel.removeCandidate(id: candidate.id)
                        }
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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

    private var selectionHint: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: QuietFrameTheme.compactSpacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: QuietFrameTheme.contentSpacing))

        return layout {
            Text("Tap items to select them, then choose Add to album. Before importing, set where any unassigned items go.")
                .font(.subheadline)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if allCandidatesSelected {
                    viewModel.clearSelection()
                } else {
                    viewModel.selectAllCandidates()
                }
            } label: {
                Text(allCandidatesSelected ? "Deselect all" : "Select all")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(QuietFrameTheme.accent)
                    .frame(minHeight: QuietFrameTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
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
                    if viewModel.albumAssignments.hasSelection {
                        selectionSummary
                        Button {
                            showsAlbumPicker = true
                        } label: {
                            Text("Add to album…")
                        }
                        .buttonStyle(.aperturePrimary)
                        .accessibilityIdentifier("add-to-album")
                    } else {
                        if !dynamicTypeSize.isAccessibilitySize, hasUnassignedCandidates {
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
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(.horizontal, QuietFrameTheme.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, QuietFrameTheme.compactSpacing)
            .frame(maxWidth: .infinity)
            .background(ground)
        }
    }

    private var selectionSummary: some View {
        let count = viewModel.albumAssignments.selectedIDs.count
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: QuietFrameTheme.compactSpacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: QuietFrameTheme.contentSpacing))

        return layout {
            Text("\(count) selected")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(QuietFrameTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewModel.clearSelection()
            } label: {
                Text("Deselect")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(QuietFrameTheme.accent)
                    .frame(minHeight: QuietFrameTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .accessibilityLabel(destinationLabel)
        .accessibilityValue(destinationName)
    }

    private var destinationLabel: String {
        viewModel.albumAssignments.hasAssignments ? "Unassigned items" : "Destination"
    }

    private var destinationTitle: some View {
        Text(destinationLabel)
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

    private var albumIDs: [UUID] {
        albums.map(\.id)
    }

    private func albumName(for candidateID: UUID) -> String? {
        guard let albumID = viewModel.albumAssignments.albumID(for: candidateID) else { return nil }
        return albums.first(where: { $0.id == albumID })?.name
    }

    private var allCandidatesSelected: Bool {
        !viewModel.candidates.isEmpty
            && viewModel.candidates.allSatisfy { viewModel.albumAssignments.isSelected($0.id) }
    }

    private var hasUnassignedCandidates: Bool {
        viewModel.candidates.contains { viewModel.albumAssignments.albumID(for: $0.id) == nil }
    }

    private func assignmentMessage(for albumID: UUID?) -> String {
        let count = viewModel.albumAssignments.selectedIDs.count
        let items = "\(count) item\(count == 1 ? "" : "s")"
        guard let albumID else { return "\(items) left unassigned" }
        guard let name = albums.first(where: { $0.id == albumID })?.name else {
            return "\(items) added to the new album"
        }
        return "\(items) added to \(name)"
    }

    private func announceAssignment() {
        guard let message = assignmentAnnouncement else { return }
        assignmentAnnouncement = nil
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
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
    let albumName: String?
    let isSelected: Bool
    let selectionMode: Bool
    let toggleSelection: () -> Void
    let remove: () -> Void

    private static let badgeInset: CGFloat = 6

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous)
    }

    private var videoDuration: TimeInterval? {
        candidate.source.metadata.mediaType == .video ? candidate.source.metadata.duration : nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: toggleSelection) {
                tile
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tileAccessibilityLabel)
            .accessibilityHint("Toggles selection for adding to an album")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: "Remove") {
                remove()
            }

            if !selectionMode {
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
        }
        .accessibilityElement(children: .contain)
    }

    private var tile: some View {
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
            .clipShape(tileShape)
            .overlay {
                if isSelected {
                    tileShape
                        .strokeBorder(QuietFrameTheme.accent, lineWidth: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected || selectionMode {
                    selectionBadge
                        .padding(Self.badgeInset)
                }
            }
            .overlay(alignment: .bottom) {
                bottomBadges
            }
            .contentShape(tileShape)
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: badgeSize * 0.46, weight: .bold))
                .foregroundStyle(QuietFrameTheme.background)
                .frame(width: badgeSize, height: badgeSize)
                .background(QuietFrameTheme.accent, in: Circle())
        } else {
            Circle()
                .fill(QuietFrameTheme.background.opacity(0.55))
                .overlay {
                    Circle().strokeBorder(QuietFrameTheme.ink, lineWidth: 1.5)
                }
                .frame(width: badgeSize, height: badgeSize)
        }
    }

    @ViewBuilder
    private var bottomBadges: some View {
        if albumName != nil || videoDuration != nil {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 4) {
                    if let albumName {
                        albumBadge(albumName)
                    }
                    Spacer(minLength: 0)
                    if let videoDuration {
                        durationText(videoDuration)
                            .layoutPriority(1)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let albumName {
                        albumBadge(albumName)
                    }
                    if let videoDuration {
                        durationText(videoDuration)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Self.badgeInset)
        }
    }

    private func durationText(_ duration: TimeInterval) -> some View {
        Text(formattedDuration(duration))
            .font(.caption.weight(.medium).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(QuietFrameTheme.background.opacity(0.78), in: Capsule())
            .foregroundStyle(QuietFrameTheme.ink)
    }

    private func albumBadge(_ name: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.stack")
                    .font(.caption2.weight(.semibold))
                Text(name)
            }
            Text(name)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(QuietFrameTheme.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(QuietFrameTheme.background.opacity(0.78), in: Capsule())
    }

    private var tileAccessibilityLabel: String {
        var parts = [candidate.source.metadata.originalFilename ?? candidate.source.metadata.mediaType.title]
        if let videoDuration {
            parts.append("video duration \(formattedDuration(videoDuration))")
        }
        parts.append(albumName.map { "album \($0)" } ?? "unassigned")
        return parts.joined(separator: ", ")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
