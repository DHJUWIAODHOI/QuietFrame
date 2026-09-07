import SwiftUI

enum QuietFrameTheme {
    static let cornerRadius: CGFloat = 20
    static let compactCornerRadius: CGFloat = 12
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    static let contentSpacing: CGFloat = 16
    static let compactSpacing: CGFloat = 8
    static let controlHeight: CGFloat = 44
    static let readableWidth: CGFloat = 560

    static let background = Color(uiColor: .systemGroupedBackground)
    static let elevated = Color(uiColor: .secondarySystemGroupedBackground)
    static let inset = Color(uiColor: .tertiarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator).opacity(0.3)
    static let ink = Color.primary
    static let quietInk = Color.secondary
    static let accent = Color.accentColor

    static let vaultGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.11, blue: 0.15), Color(red: 0.17, green: 0.18, blue: 0.29)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    func quietCard() -> some View {
        background(QuietFrameTheme.elevated, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius))
    }

    func quietFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(QuietFrameTheme.background)
    }
}

struct QuietSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 28, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(QuietFrameTheme.accent)
            .frame(width: 64, height: 64)
            .background(QuietFrameTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius))
            .accessibilityHidden(true)
    }
}

struct QuietIntroduction: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: QuietFrameTheme.contentSpacing) {
            QuietSymbol(systemName: systemImage)
            VStack(spacing: QuietFrameTheme.compactSpacing) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: QuietFrameTheme.readableWidth)
    }
}

struct QuietSettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: QuietFrameTheme.contentSpacing) {
            configuration.icon
                .font(.body.weight(.medium))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
