import SwiftUI

enum QuietFrameTheme {
    static let cornerRadius: CGFloat = 18
    static let compactCornerRadius: CGFloat = 12
    static let pagePadding: CGFloat = 20

    static let background = Color(uiColor: .systemGroupedBackground)
    static let elevated = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color.primary
    static let quietInk = Color.secondary
    static let accent = Color.accentColor

    static let vaultGradient = LinearGradient(
        colors: [Color(red: 0.12, green: 0.13, blue: 0.19), Color(red: 0.22, green: 0.16, blue: 0.34)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct QuietCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(QuietFrameTheme.elevated, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous))
    }
}

extension View {
    func quietCard() -> some View {
        modifier(QuietCardModifier())
    }
}
