import SwiftUI

struct StorageManagementView: View {
    let service: any StorageAnalyzing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var summary: StorageSummary?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
                        totalCard(summary)
                        breakdown(summary)
                        counts(summary)
                        largestFiles(summary)
                    }
                    .frame(maxWidth: QuietFrameTheme.readableWidth)
                    .padding(QuietFrameTheme.pagePadding)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await load() }
            } else if isLoading {
                ProgressView("Analyzing encrypted storage")
                    .controlSize(.large)
                    .padding(QuietFrameTheme.pagePadding)
            } else {
                ContentUnavailableView(
                    "Storage Unavailable",
                    systemImage: "internaldrive.badge.exclamationmark",
                    description: Text(errorMessage ?? VaultError.fileOperationFailed.localizedDescription)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuietFrameTheme.background)
        .tint(QuietFrameTheme.accent)
        .labelStyle(QuietSettingsLabelStyle())
        .labeledContentStyle(SettingsValueStyle())
        .navigationTitle("Storage Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func totalCard(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
            Label("Encrypted Vault", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(QuietFrameTheme.accent)
            Text(formatted(summary.totalEncryptedBytes))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text("Actual encrypted files and private previews stored in the app sandbox.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(QuietFrameTheme.pagePadding)
        .quietCard()
        .overlay {
            RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius)
                .strokeBorder(QuietFrameTheme.accent.opacity(0.2), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func breakdown(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
            Text("Breakdown")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            storageRow("Photos", symbol: "photo", bytes: summary.photoBytes, total: summary.totalEncryptedBytes)
            storageRow("Videos", symbol: "video", bytes: summary.videoBytes, total: summary.totalEncryptedBytes)
            storageRow("Private Previews", symbol: "square.grid.3x3", bytes: summary.thumbnailBytes, total: summary.totalEncryptedBytes)
            storageRow("Trash", symbol: "trash", bytes: summary.trashBytes, total: summary.totalEncryptedBytes)
        }
        .padding(QuietFrameTheme.pagePadding)
        .quietCard()
    }

    private func storageRow(_ title: String, symbol: String, bytes: Int64, total: Int64) -> some View {
        VStack(spacing: QuietFrameTheme.compactSpacing) {
            LabeledContent {
                Text(formatted(bytes))
                    .monospacedDigit()
            } label: {
                Label(title, systemImage: symbol)
            }
            .font(.subheadline)
            ProgressView(value: total > 0 ? Double(bytes) / Double(total) : 0)
                .accessibilityLabel("\(title) storage")
                .accessibilityValue(formatted(bytes))
        }
    }

    private func counts(_ summary: StorageSummary) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: QuietFrameTheme.contentSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: QuietFrameTheme.contentSpacing))

        return layout {
            metricCard("Media", value: summary.mediaCount, symbol: "photo.stack")
            metricCard("Albums", value: summary.albumCount, symbol: "rectangle.stack")
        }
    }

    private func metricCard(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(value, format: .number)
                .font(.title2.weight(.semibold).monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(QuietFrameTheme.pagePadding)
        .quietCard()
        .accessibilityElement(children: .combine)
    }

    private func largestFiles(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
            Text("Largest Files")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if summary.largestItems.isEmpty {
                Text("No active media")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.largestItems) { item in
                    HStack(alignment: .top, spacing: QuietFrameTheme.contentSpacing) {
                        Image(systemName: item.mediaType.symbolName)
                            .font(.body.weight(.medium))
                            .frame(width: QuietFrameTheme.controlHeight, height: QuietFrameTheme.controlHeight)
                            .background(QuietFrameTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
                            Text(item.name)
                                .font(.body.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            LabeledContent(item.mediaType == .photo ? "Photo" : "Video") {
                                Text(formatted(item.byteCount))
                                    .monospacedDigit()
                            }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, QuietFrameTheme.compactSpacing)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(QuietFrameTheme.pagePadding)
        .quietCard()
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
