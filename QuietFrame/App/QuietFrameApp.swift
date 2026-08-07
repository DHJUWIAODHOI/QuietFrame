import SwiftUI

@main
struct QuietFrameApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .task {
                    await appModel.bootstrapIfNeeded()
                }
        }
    }
}
