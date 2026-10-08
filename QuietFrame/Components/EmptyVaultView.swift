import SwiftUI

struct EmptyVaultView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: QuietFrameTheme.sectionSpacing) {
            VStack(spacing: QuietFrameTheme.contentSpacing) {
                ApertureIris(closure: 1, filledBlades: 0, size: 88)
                    .accessibilityHidden(true)
                VStack(spacing: QuietFrameTheme.compactSpacing) {
                    Text(title)
                        .font(QuietFrameTheme.titleFont)
                        .foregroundStyle(QuietFrameTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(QuietFrameTheme.quietInk)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: action) {
                Label(actionTitle, systemImage: "plus")
            }
            .buttonStyle(.aperturePrimary)
            .accessibilityIdentifier("choose-media")
        }
        .frame(maxWidth: QuietFrameTheme.readableWidth)
        .padding(QuietFrameTheme.pagePadding)
        .frame(maxWidth: .infinity)
    }
}
