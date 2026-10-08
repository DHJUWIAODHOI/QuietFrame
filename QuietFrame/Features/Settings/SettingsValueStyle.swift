import SwiftUI

struct SettingsValueStyle: LabeledContentStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let layout = isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: QuietFrameTheme.compactSpacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: QuietFrameTheme.contentSpacing))

        return layout {
            configuration.label
                .foregroundStyle(QuietFrameTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !isAccessibilitySize {
                Spacer(minLength: 0)
            }
            configuration.content
                .foregroundStyle(QuietFrameTheme.quietInk)
                .monospacedDigit()
                .multilineTextAlignment(isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
