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
    @State private var pendingAssignment: PendingAssignment?

    private struct PendingAssignment {
        let albumID: UUID?
    }

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
        .sheet(isPresented: $showsAlbumPicker, onDismiss: { finishAlbumAssignment() }) { albumPicker }
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
            pendingAssignment = PendingAssignment(albumID: albumID)
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
                    VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
                        Text("Encrypting \(min(viewModel.progress.completedItems + 1, viewModel.progress.totalItems)) of \(viewModel.progress.totalItems)")
                            .font(QuietFrameTheme.titleFont.monospacedDigit())
                            .foregroundStyle(QuietFrameTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("You can cancel safely. A partially encrypted item is removed before the import stops.")
                            .font(.subheadline)
                            .foregroundStyle(QuietFrameTheme.quietInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ImportSealProgressBar(fraction: importFraction)
                        .animation(reduceMotion ? nil : ImportReviewMotion.progress, value: importFraction)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Import progress")
                        .accessibilityValue(Text(viewModel.progress.overallFraction, format: .percent))
                        .accessibilityAddTraits(.updatesFrequently)

                    LazyVGrid(columns: columns, spacing: QuietFrameTheme.gridSpacing) {
                        ForEach(Array(viewModel.candidates.enumerated()), id: \.element.id) { index, candidate in
                            ImportSealingCell(
                                candidate: candidate,
                                albumName: albumName(for: candidate.id),
                                state: sealState(at: index)
                            )
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            .id(candidate.id)
                        }
                    }
                }
                .frame(maxWidth: QuietFrameTheme.readableWidth)
                .padding(.horizontal, QuietFrameTheme.pagePadding)
                .padding(.top, QuietFrameTheme.contentSpacing)
                .padding(.bottom, QuietFrameTheme.pagePadding)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: sealingCandidateID) { _, candidateID in
                guard let candidateID else { return }
                if reduceMotion {
                    proxy.scrollTo(candidateID)
                } else {
                    withAnimation(ImportReviewMotion.scroll) {
                        proxy.scrollTo(candidateID)
                    }
                }
            }
        }
    }

    private var previewGrid: some View {
        let delays = labelDelays
        return ScrollView {
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
                            labelDelay: delays[candidate.id] ?? 0,
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

    private func finishAlbumAssignment() {
        if let pending = pendingAssignment {
            pendingAssignment = nil
            viewModel.assignSelection(toAlbumID: pending.albumID)
        }
        announceAssignment()
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

    private var importFraction: Double {
        let value = viewModel.progress.overallFraction
        return value.isFinite ? min(max(value, 0), 1) : 0
    }

    private var sealingFraction: Double {
        let value = viewModel.progress.currentItemFraction / 0.9
        return value.isFinite ? min(max(value, 0), 1) : 0
    }

    private func sealState(at index: Int) -> ImportSealState {
        let completedItems = viewModel.progress.completedItems
        if index < completedItems { return .sealed }
        if index == completedItems { return .sealing(sealingFraction) }
        return .waiting
    }

    private var sealingCandidateID: UUID? {
        let index = viewModel.progress.completedItems
        guard viewModel.candidates.indices.contains(index) else { return nil }
        return viewModel.candidates[index].id
    }

    private var labelDelays: [UUID: Double] {
        let assignedIDs = viewModel.albumAssignments.lastAssignedIDs
        var delays: [UUID: Double] = [:]
        for candidate in viewModel.candidates where assignedIDs.contains(candidate.id) {
            delays[candidate.id] = min(
                Double(delays.count) * ImportReviewMotion.labelStagger,
                ImportReviewMotion.labelStaggerLimit
            )
        }
        return delays
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

private enum ImportReviewMotion {
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    static let selectionIn = easeOut(0.14)
    static let selectionOut = easeOut(0.1)
    static let labelIn = easeOut(0.22)
    static let labelOut = easeOut(0.1)
    static let labelStagger = 0.04
    static let labelStaggerLimit = 0.4
    static let lockIn = easeOut(0.16)
    static let sealFade = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.22)
    static let progress = Animation.linear(duration: 0.15)
    static let scroll = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.35)
}

private extension ImportPreviewCandidate {
    var videoDuration: TimeInterval? {
        source.metadata.mediaType == .video ? source.metadata.duration : nil
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func accessibilityParts(albumName: String?) -> [String] {
        var parts = [source.metadata.originalFilename ?? source.metadata.mediaType.title]
        if let videoDuration {
            parts.append("video duration \(Self.formattedDuration(videoDuration))")
        }
        parts.append(albumName.map { "album \($0)" } ?? "unassigned")
        return parts
    }
}

private struct ImportTileArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let candidate: ImportPreviewCandidate
    let albumName: String?
    var labelDelay: Double = 0
    var animatesLabel = true

    static let badgeInset: CGFloat = 6

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous)
    }

    var body: some View {
        Rectangle()
            .fill(QuietFrameTheme.inset)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                preview
            }
            .overlay(alignment: .bottom) {
                bottomBadges
            }
    }

    @ViewBuilder
    private var preview: some View {
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

    private var bottomBadges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 4) {
                albumLabel
                Spacer(minLength: 0)
                if let videoDuration = candidate.videoDuration {
                    durationText(videoDuration)
                        .layoutPriority(1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                albumLabel
                if let videoDuration = candidate.videoDuration {
                    durationText(videoDuration)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Self.badgeInset)
        .animation(labelAnimation, value: albumName)
    }

    private var albumLabel: some View {
        ZStack(alignment: .bottomLeading) {
            if let albumName {
                albumBadge(albumName)
                    .transition(labelTransition)
                    .id(albumName)
            }
        }
    }

    private var labelAnimation: Animation? {
        guard animatesLabel else { return nil }
        guard albumName != nil else { return ImportReviewMotion.labelOut }
        return ImportReviewMotion.labelIn.delay(labelDelay)
    }

    private var labelTransition: AnyTransition {
        guard animatesLabel else { return .identity }
        let insertion: AnyTransition = reduceMotion
            ? .opacity
            : AnyTransition.move(edge: .bottom).combined(with: .opacity)
        return .asymmetric(
            insertion: insertion,
            removal: AnyTransition.opacity.animation(ImportReviewMotion.labelOut)
        )
    }

    private func durationText(_ duration: TimeInterval) -> some View {
        Text(ImportPreviewCandidate.formattedDuration(duration))
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
}

private struct ImportPreviewCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 26
    let candidate: ImportPreviewCandidate
    let albumName: String?
    let isSelected: Bool
    let selectionMode: Bool
    let labelDelay: Double
    let toggleSelection: () -> Void
    let remove: () -> Void

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
        ImportTileArtwork(candidate: candidate, albumName: albumName, labelDelay: labelDelay)
            .overlay {
                ImportTileArtwork.shape
                    .strokeBorder(QuietFrameTheme.accent, lineWidth: 3)
                    .opacity(isSelected ? 1 : 0)
                    .animation(selectionAnimation, value: isSelected)
            }
            .overlay(alignment: .topTrailing) {
                selectionBadge
                    .padding(ImportTileArtwork.badgeInset)
                    .animation(selectionAnimation, value: isSelected)
            }
            .clipShape(ImportTileArtwork.shape)
            .contentShape(ImportTileArtwork.shape)
    }

    private var selectionAnimation: Animation {
        isSelected ? ImportReviewMotion.selectionIn : ImportReviewMotion.selectionOut
    }

    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(QuietFrameTheme.background.opacity(0.55))
                .overlay {
                    Circle().strokeBorder(QuietFrameTheme.ink, lineWidth: 1.5)
                }
                .opacity(selectionMode && !isSelected ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: badgeSize * 0.46, weight: .bold))
                .foregroundStyle(QuietFrameTheme.background)
                .frame(width: badgeSize, height: badgeSize)
                .background(QuietFrameTheme.accent, in: Circle())
                .scaleEffect(isSelected || reduceMotion ? 1 : 0.9)
                .opacity(isSelected ? 1 : 0)
        }
        .frame(width: badgeSize, height: badgeSize)
    }

    private var tileAccessibilityLabel: String {
        candidate.accessibilityParts(albumName: albumName).joined(separator: ", ")
    }
}

private enum ImportSealState: Equatable {
    case waiting
    case sealing(Double)
    case sealed
}

private struct ImportSealingCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let candidate: ImportPreviewCandidate
    let albumName: String?
    let state: ImportSealState

    var body: some View {
        ImportTileArtwork(candidate: candidate, albumName: albumName, animatesLabel: false)
            .overlay {
                sweep
            }
            .overlay {
                Rectangle()
                    .fill(QuietFrameTheme.background.opacity(0.58))
                    .opacity(isSealed ? 1 : 0)
                    .animation(ImportReviewMotion.sealFade, value: isSealed)
            }
            .overlay {
                lock
            }
            .clipShape(ImportTileArtwork.shape)
            .opacity(isWaiting ? 0.75 : 1)
            .animation(ImportReviewMotion.sealFade, value: isWaiting)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var sweep: some View {
        if reduceMotion {
            Rectangle()
                .fill(QuietFrameTheme.accent)
                .opacity(isSealing ? 0.35 : 0)
                .animation(ImportReviewMotion.sealFade, value: isSealing)
        } else {
            Rectangle()
                .fill(QuietFrameTheme.accent)
                .scaleEffect(x: CGFloat(sweepFraction), y: 1, anchor: .leading)
                .animation(ImportReviewMotion.progress, value: sweepFraction)
                .opacity(isSealing ? 1 : 0)
                .animation(ImportReviewMotion.sealFade, value: isSealing)
        }
    }

    private var lock: some View {
        Image(systemName: "lock.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(QuietFrameTheme.ink)
            .scaleEffect(isSealed || reduceMotion ? 1 : 0.9)
            .opacity(isSealed ? 1 : 0)
            .animation(ImportReviewMotion.lockIn, value: isSealed)
    }

    private var isWaiting: Bool {
        state == .waiting
    }

    private var isSealed: Bool {
        state == .sealed
    }

    private var isSealing: Bool {
        switch state {
        case .sealing: true
        case .waiting, .sealed: false
        }
    }

    private var sweepFraction: Double {
        switch state {
        case .waiting: 0
        case .sealing(let fraction): fraction
        case .sealed: 1
        }
    }

    private var statusText: String {
        switch state {
        case .waiting: "waiting"
        case .sealing: "encrypting"
        case .sealed: "done"
        }
    }

    private var accessibilityText: String {
        (candidate.accessibilityParts(albumName: albumName) + [statusText]).joined(separator: ", ")
    }
}

private struct ImportSealProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(QuietFrameTheme.inset)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(QuietFrameTheme.accent)
                    .scaleEffect(x: CGFloat(fraction), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
    }
}
