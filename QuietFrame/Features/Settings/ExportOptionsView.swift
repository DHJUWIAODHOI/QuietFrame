import SwiftUI

struct ExportOptionsView: View {
    var body: some View {
        List {
            Section("Quality") {
                LabeledContent("Media Quality", value: "Original")
                LabeledContent("Compression", value: "None")
                LabeledContent("Video Transcoding", value: "None")
            }

            Section("Metadata") {
                LabeledContent("Embedded Metadata", value: "Preserved")
                LabeledContent("Photos Creation Date", value: "Preserved")
            }

            Section {
                Text("QuietFrame does not alter media during export. Native share destinations may process a file according to their own policies after you hand it off.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Export Behavior")
        .navigationBarTitleDisplayMode(.inline)
    }
}
