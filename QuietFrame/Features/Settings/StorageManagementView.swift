import SwiftUI

struct StorageManagementView: View {
    let service: any StorageAnalyzing

    @State private var summary: StorageSummary?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        totalCard(summary)
                        breakdown(summary)
                        counts(summary)
                        largestFiles(summary)
                    }
                    .padding(QuietFrameTheme.pagePadding)
                }
                .background(QuietFrameTheme.background)
                .refreshable { await load() }
            } else if isLoading {
                ProgressView("Analyzing encrypted storage")
            } else {
                ContentUnavailableView(
                    "Storage Unavailable",
                    systemImage: "internaldrive.badge.exclamationmark",
                    description: Text(errorMessage ?? VaultError.fileOperationFailed.localizedDescription)
                )
            }
        }
        .navigationTitle("Storage Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func totalCard(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Encrypted Vault", systemImage: "lock.shield.fill")
                .font(.headline)
            Text(formatted(summary.totalEncryptedBytes))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.7)
            Text("Actual encrypted files and private previews stored in the app sandbox.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .quietCard()
        .accessibilityElement(children: .combine)
    }

    private func breakdown(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Breakdown")
                .font(.title3.bold())
            storageRow("Photos", symbol: "photo", bytes: summary.photoBytes, total: summary.totalEncryptedBytes)
            storageRow("Videos", symbol: "video", bytes: summary.videoBytes, total: summary.totalEncryptedBytes)
            storageRow("Private Previews", symbol: "square.grid.3x3", bytes: summary.thumbnailBytes, total: summary.totalEncryptedBytes)
            storageRow("Trash", symbol: "trash", bytes: summary.trashBytes, total: summary.totalEncryptedBytes)
        }
        .padding(18)
        .quietCard()
    }

    private func storageRow(_ title: String, symbol: String, bytes: Int64, total: Int64) -> some View {
        VStack(spacing: 7) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(formatted(bytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: total > 0 ? Double(bytes) / Double(total) : 0)
                .accessibilityLabel("\(title) storage")
                .accessibilityValue(formatted(bytes))
        }
    }

    private func counts(_ summary: StorageSummary) -> some View {
        HStack(spacing: 12) {
            metricCard("Media", value: summary.mediaCount, symbol: "photo.stack")
            metricCard("Albums", value: summary.albumCount, symbol: "rectangle.stack")
        }
    }

    private func metricCard(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
            Text(value, format: .number)
                .font(.title2.bold().monospacedDigit())
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .quietCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func largestFiles(_ summary: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Largest Files")
                .font(.title3.bold())
            if summary.largestItems.isEmpty {
                Text("No active media")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.largestItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.mediaType.symbolName)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .lineLimit(1)
                            Text(item.mediaType == .photo ? "Photo" : "Video")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatted(item.byteCount))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(18)
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
