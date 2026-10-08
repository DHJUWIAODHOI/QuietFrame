import SwiftUI

@main
struct QuietFrameApp: App {
    @State private var appModel = AppModel()

    init() {
        QuietFrameTheme.applyGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .preferredColorScheme(.dark)
                .tint(QuietFrameTheme.accent)
                .foregroundStyle(QuietFrameTheme.ink)
                .task {
                    await appModel.bootstrapIfNeeded()
                }
        }
    }
}
