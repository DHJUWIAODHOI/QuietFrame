import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                VaultScreen()
            }
            .tabItem {
                Label("Vault", systemImage: "square.grid.2x2.fill")
            }

            NavigationStack {
                AlbumsScreen()
            }
            .tabItem {
                Label("Albums", systemImage: "rectangle.stack.fill")
            }

            NavigationStack {
                TrashScreen()
            }
            .tabItem {
                Label("Trash", systemImage: "trash.fill")
            }

            NavigationStack {
                SettingsScreen()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .tint(QuietFrameTheme.accent)
        .accessibilityIdentifier("main-tabs")
    }
}
