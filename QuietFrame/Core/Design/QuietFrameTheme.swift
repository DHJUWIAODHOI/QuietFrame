import SwiftUI
import UIKit

/// The Aperture design system: a calm, always-dark night palette with brass reserved
/// for the iris, primary actions and selection.
enum QuietFrameTheme {
    static let cornerRadius: CGFloat = 16
    static let compactCornerRadius: CGFloat = 12
    static let tileCornerRadius: CGFloat = 10
    static let sheetCornerRadius: CGFloat = 28
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 28
    static let contentSpacing: CGFloat = 16
    static let compactSpacing: CGFloat = 8
    static let controlHeight: CGFloat = 44
    static let primaryButtonHeight: CGFloat = 52
    static let gridSpacing: CGFloat = 6
    static let readableWidth: CGFloat = 560

    // Palette
    static let nightUI = UIColor(red: 0x13 / 255, green: 0x1B / 255, blue: 0x2E / 255, alpha: 1)
    static let duskUI = UIColor(red: 0x1C / 255, green: 0x27 / 255, blue: 0x40 / 255, alpha: 1)
    static let slateUI = UIColor(red: 0x2A / 255, green: 0x37 / 255, blue: 0x57 / 255, alpha: 1)
    static let moonUI = UIColor(red: 0xEC / 255, green: 0xEF / 255, blue: 0xF6 / 255, alpha: 1)
    static let mistUI = UIColor(red: 0xA3 / 255, green: 0xAE / 255, blue: 0xC4 / 255, alpha: 1)
    static let brassUI = UIColor(red: 0xE3 / 255, green: 0xBE / 255, blue: 0x7C / 255, alpha: 1)
    static let emberUI = UIColor(red: 0xF2 / 255, green: 0x93 / 255, blue: 0x7E / 255, alpha: 1)

    /// Screen ground.
    static let night = Color(uiColor: nightUI)
    /// Sheets, grouped rows, fields and the tab bar.
    static let dusk = Color(uiColor: duskUI)
    /// Raised controls, dividers and empty iris blades.
    static let slate = Color(uiColor: slateUI)
    /// Primary text.
    static let moon = Color(uiColor: moonUI)
    /// Secondary text.
    static let mist = Color(uiColor: mistUI)
    /// The iris, primary buttons and selection. Use sparingly.
    static let brass = Color(uiColor: brassUI)
    /// Destructive text only.
    static let ember = Color(uiColor: emberUI)

    // Semantic names used throughout the app.
    static let background = night
    static let elevated = dusk
    static let inset = slate
    static let separator = slate
    static let ink = moon
    static let quietInk = mist
    static let accent = brass
    static let destructive = ember

    /// Opaque cover used behind launch and privacy screens.
    static let vaultGradient = LinearGradient(
        colors: [night, Color(red: 0x17 / 255, green: 0x21 / 255, blue: 0x38 / 255)],
        startPoint: .top,
        endPoint: .bottom
    )

    // Typography: New York for titles, SF Pro for everything else.
    static let screenTitleFont = Font.system(.largeTitle, design: .serif).weight(.regular)
    static let titleFont = Font.system(.title, design: .serif).weight(.regular)
    static let sectionTitleFont = Font.system(.title3, design: .serif).weight(.medium)

    static func serifUIFont(size: CGFloat, weight: UIFont.Weight, textStyle: UIFont.TextStyle) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: UIFont(descriptor: descriptor, size: size))
    }

    /// Applies the Aperture look to UIKit-backed navigation bars, tab bars and controls.
    @MainActor
    static func applyGlobalAppearance() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = nightUI
        navigation.shadowColor = .clear
        navigation.titleTextAttributes = [
            .foregroundColor: moonUI,
            .font: serifUIFont(size: 17, weight: .semibold, textStyle: .headline)
        ]
        navigation.largeTitleTextAttributes = [
            .foregroundColor: moonUI,
            .font: serifUIFont(size: 34, weight: .regular, textStyle: .largeTitle)
        ]
        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = navigation
        navigationBar.scrollEdgeAppearance = navigation
        navigationBar.compactAppearance = navigation
        navigationBar.compactScrollEdgeAppearance = navigation
        navigationBar.tintColor = brassUI

        let item = UITabBarItemAppearance()
        item.normal.iconColor = mistUI
        item.normal.titleTextAttributes = [.foregroundColor: mistUI]
        item.selected.iconColor = brassUI
        item.selected.titleTextAttributes = [.foregroundColor: moonUI]
        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = duskUI
        tabs.shadowColor = slateUI
        tabs.stackedLayoutAppearance = item
        tabs.inlineLayoutAppearance = item
        tabs.compactInlineLayoutAppearance = item
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tabs
        tabBar.scrollEdgeAppearance = tabs

        UISwitch.appearance().onTintColor = brassUI
    }
}

extension View {
    /// A Dusk surface with the standard group radius.
    func quietCard() -> some View {
        background(QuietFrameTheme.elevated, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous))
    }

    /// Night ground behind a `List` or `Form`. Pair with `quietRows()` on its sections.
    func quietFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(QuietFrameTheme.background)
    }

    /// Dusk rows with Slate dividers inside a `List` or `Form` section.
    func quietRows() -> some View {
        listRowBackground(QuietFrameTheme.elevated)
            .listRowSeparatorTint(QuietFrameTheme.separator)
    }

    /// Serif large-title treatment for headings drawn outside a navigation bar.
    func quietScreenTitle() -> some View {
        font(QuietFrameTheme.screenTitleFont)
            .foregroundStyle(QuietFrameTheme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Pill buttons: brass primary, dusk secondary, ember destructive.
struct ApertureButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
    }

    var kind: Kind = .primary
    var fillsWidth = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: minimumHeight)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }

    private var minimumHeight: CGFloat {
        kind == .primary ? QuietFrameTheme.primaryButtonHeight : QuietFrameTheme.controlHeight + 4
    }

    private var foreground: Color {
        switch kind {
        case .primary: QuietFrameTheme.night
        case .secondary: QuietFrameTheme.ink
        case .destructive: QuietFrameTheme.destructive
        }
    }

    private var background: Color {
        switch kind {
        case .primary: QuietFrameTheme.accent
        case .secondary, .destructive: QuietFrameTheme.elevated
        }
    }
}

extension ButtonStyle where Self == ApertureButtonStyle {
    static var aperturePrimary: ApertureButtonStyle { ApertureButtonStyle(kind: .primary) }
    static var apertureSecondary: ApertureButtonStyle { ApertureButtonStyle(kind: .secondary) }
    static var apertureDestructive: ApertureButtonStyle { ApertureButtonStyle(kind: .destructive) }
}

/// A brass symbol on a Dusk tile, used by introductions and empty states.
struct QuietSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(QuietFrameTheme.accent)
            .frame(width: 64, height: 64)
            .background(QuietFrameTheme.elevated, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous))
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
        .frame(maxWidth: QuietFrameTheme.readableWidth)
    }
}

struct QuietSettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: QuietFrameTheme.contentSpacing) {
            configuration.icon
                .font(.body.weight(.regular))
                .foregroundStyle(QuietFrameTheme.quietInk)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            configuration.title
                .foregroundStyle(QuietFrameTheme.ink)
        }
    }
}
