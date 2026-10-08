import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                VaultScreen()
            }
            .tabItem {
                Label("Vault", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                AlbumsScreen()
            }
            .tabItem {
                Label("Albums", systemImage: "rectangle.stack")
            }

            NavigationStack {
                TrashScreen()
            }
            .tabItem {
                Label("Trash", systemImage: "trash")
            }

            NavigationStack {
                SettingsScreen()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(QuietFrameTheme.accent)
        .background(QuietFrameTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("main-tabs")
    }
}
