import SwiftUI

struct ExportOptionsView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Media quality", value: "Original")
                LabeledContent("Compression", value: "None")
                LabeledContent("Video transcoding", value: "None")
            } header: {
                sectionHeader("Quality")
            }
            .quietRows()

            Section {
                LabeledContent("Embedded metadata", value: "Preserved")
                LabeledContent("Photos creation date", value: "Preserved")
            } header: {
                sectionHeader("Metadata")
            }
            .quietRows()

            Section {
                Text("QuietFrame does not alter media during export. Native share destinations may process a file according to their own policies after you hand it off.")
                    .font(.body)
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, QuietFrameTheme.compactSpacing)
            }
            .quietRows()
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(QuietFrameTheme.sectionSpacing)
        .labeledContentStyle(SettingsValueStyle())
        .quietFormStyle()
        .frame(maxWidth: QuietFrameTheme.readableWidth + 2 * QuietFrameTheme.pagePadding)
        .frame(maxWidth: .infinity)
        .background(QuietFrameTheme.background)
        .navigationTitle("Export behavior")
        .navigationBarTitleDisplayMode(.large)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(QuietFrameTheme.sectionTitleFont)
            .foregroundStyle(QuietFrameTheme.ink)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}
