import SwiftUI

struct AuthenticationLayout<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: QuietFrameTheme.sectionSpacing) {
                    content
                }
                .frame(maxWidth: QuietFrameTheme.readableWidth)
                .padding(QuietFrameTheme.pagePadding)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(QuietFrameTheme.background.ignoresSafeArea())
        .tint(QuietFrameTheme.accent)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: QuietFrameTheme.compactCornerRadius))
    }
}

struct AuthenticationErrorMessage: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
