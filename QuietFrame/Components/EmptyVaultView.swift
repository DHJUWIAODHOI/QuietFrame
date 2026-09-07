import SwiftUI

struct EmptyVaultView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: QuietFrameTheme.sectionSpacing) {
            QuietIntroduction(
                title: title,
                message: message,
                systemImage: "photo.on.rectangle.angled"
            )

            Button(action: action) {
                Label(actionTitle, systemImage: "plus")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: QuietFrameTheme.compactCornerRadius))
            .controlSize(.large)
            .accessibilityIdentifier("choose-media")
        }
        .frame(maxWidth: QuietFrameTheme.readableWidth)
        .padding(QuietFrameTheme.pagePadding)
        .frame(maxWidth: .infinity)
    }
}
