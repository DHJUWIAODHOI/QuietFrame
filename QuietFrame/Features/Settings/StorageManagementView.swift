import SwiftUI

struct StorageManagementView: View {
    let service: any StorageAnalyzing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .largeTitle) private var totalFontSize: CGFloat = 44

    @State private var summary: StorageSummary?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: QuietFrameTheme.sectionSpacing) {
                        totalSummary(summary)
                        breakdown(summary)
                        counts(summary)
                        largestFiles(summary)
                        Text("Actual encrypted files and private previews stored in the app sandbox.")
                            .font(.subheadline)
                            .foregroundStyle(QuietFrameTheme.quietInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: QuietFrameTheme.readableWidth)
                    .padding(QuietFrameTheme.pagePadding)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await load() }
            } else if isLoading {
                ProgressView("Analyzing encrypted storage")
                    .controlSize(.large)
                    .tint(QuietFrameTheme.quietInk)
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .padding(QuietFrameTheme.pagePadding)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Storage unavailable")
                            .font(QuietFrameTheme.titleFont)
                            .foregroundStyle(QuietFrameTheme.ink)
                    } icon: {
                        Image(systemName: "internaldrive.badge.exclamationmark")
                            .foregroundStyle(QuietFrameTheme.quietInk)
                    }
                } description: {
                    Text(errorMessage ?? VaultError.fileOperationFailed.localizedDescription)
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuietFrameTheme.background)
        .tint(QuietFrameTheme.accent)
        .navigationTitle("Storage usage")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private func totalSummary(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatted(summary.totalEncryptedBytes))
                .font(.system(size: totalFontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(QuietFrameTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Encrypted vault")
                .font(.subheadline)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func breakdown(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
            sectionHeader("Breakdown")
            VStack(spacing: 0) {
                storageRow("Photos", bytes: summary.photoBytes, total: summary.totalEncryptedBytes)
                rowDivider(leading: QuietFrameTheme.contentSpacing)
                storageRow("Videos", bytes: summary.videoBytes, total: summary.totalEncryptedBytes)
                rowDivider(leading: QuietFrameTheme.contentSpacing)
                storageRow("Private previews", bytes: summary.thumbnailBytes, total: summary.totalEncryptedBytes)
                rowDivider(leading: QuietFrameTheme.contentSpacing)
                storageRow("Trash", bytes: summary.trashBytes, total: summary.totalEncryptedBytes)
            }
            .quietCard()
        }
    }

    private func storageRow(_ title: String, bytes: Int64, total: Int64) -> some View {
        let fraction = total > 0 ? min(max(Double(bytes) / Double(total), 0), 1) : 0
        let share = fraction.formatted(.percent.precision(.fractionLength(0)))
        let layout = rowLayout
        return VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
            layout {
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(QuietFrameTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: QuietFrameTheme.compactSpacing)
                }
                Text(formatted(bytes))
                    .monospacedDigit()
                    .foregroundStyle(QuietFrameTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StorageShareBar(fraction: fraction)
        }
        .padding(.horizontal, QuietFrameTheme.contentSpacing)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) storage")
        .accessibilityValue("\(formatted(bytes)), \(share) of the vault")
    }

    private func counts(_ summary: StorageSummary) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: QuietFrameTheme.compactSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: QuietFrameTheme.compactSpacing))

        return layout {
            metricCard("Media", value: summary.mediaCount, symbol: "photo.stack")
            metricCard("Albums", value: summary.albumCount, symbol: "rectangle.stack")
        }
    }

    private func metricCard(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .accessibilityHidden(true)
            Text(value, format: .number)
                .font(QuietFrameTheme.titleFont)
                .monospacedDigit()
                .foregroundStyle(QuietFrameTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(QuietFrameTheme.contentSpacing)
        .quietCard()
        .accessibilityElement(children: .combine)
    }

    private func largestFiles(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
            sectionHeader("Largest files")
            VStack(spacing: 0) {
                if summary.largestItems.isEmpty {
                    Text("No active media")
                        .foregroundStyle(QuietFrameTheme.quietInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, QuietFrameTheme.contentSpacing)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                } else {
                    ForEach(summary.largestItems) { item in
                        if item.id != summary.largestItems.first?.id {
                            rowDivider(leading: QuietFrameTheme.contentSpacing + 36 + 12)
                        }
                        largeFileRow(item)
                    }
                }
            }
            .quietCard()
        }
    }

    private func largeFileRow(_ item: LargeMediaItem) -> some View {
        let typeTitle = item.mediaType == .photo ? "Photo" : "Video"
        let layout = rowLayout
        return HStack(spacing: 12) {
            Image(systemName: item.mediaType.symbolName)
                .font(.subheadline)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .frame(width: 36, height: 36)
                .background(QuietFrameTheme.inset, in: RoundedRectangle(cornerRadius: QuietFrameTheme.tileCornerRadius, style: .continuous))
                .accessibilityHidden(true)
            layout {
                Text(item.name)
                    .foregroundStyle(QuietFrameTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: QuietFrameTheme.compactSpacing)
                }
                Text(formatted(item.byteCount))
                    .monospacedDigit()
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, QuietFrameTheme.contentSpacing)
        .padding(.vertical, QuietFrameTheme.compactSpacing)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue("\(typeTitle), \(formatted(item.byteCount))")
    }

    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: QuietFrameTheme.compactSpacing))
    }

    private func rowDivider(leading: CGFloat) -> some View {
        Rectangle()
            .fill(QuietFrameTheme.separator)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(QuietFrameTheme.sectionTitleFont)
            .foregroundStyle(QuietFrameTheme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func load() async {
        isLoading = true
        do {
            summary = try await service.analyze()
            errorMessage = nil
        } catch {
            summary = nil
            errorMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.fileOperationFailed.localizedDescription
        }
        isLoading = false
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct StorageShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(QuietFrameTheme.inset)
                Capsule()
                    .fill(QuietFrameTheme.quietInk)
                    .frame(width: fillWidth(in: proxy.size.width))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func fillWidth(in width: CGFloat) -> CGFloat {
        guard fraction > 0 else { return 0 }
        return min(width, max(width * CGFloat(fraction), 6))
    }
}
