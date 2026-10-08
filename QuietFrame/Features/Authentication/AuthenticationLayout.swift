import SwiftUI

struct AuthenticationLayout<Content: View>: View {
    @ViewBuilder let content: (_ isCompactHeight: Bool) -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content(proxy.size.height < 700)
                }
                .frame(maxWidth: QuietFrameTheme.readableWidth)
                .padding(.horizontal, QuietFrameTheme.pagePadding)
                .padding(.vertical, QuietFrameTheme.contentSpacing)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(QuietFrameTheme.background.ignoresSafeArea())
        .foregroundStyle(QuietFrameTheme.ink)
        .tint(QuietFrameTheme.accent)
    }
}

struct AuthenticationErrorMessage: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(QuietFrameTheme.ink)
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(QuietFrameTheme.destructive)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
