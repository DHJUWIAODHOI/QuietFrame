import SwiftUI

struct VaultScreen: View {
    var body: some View {
        GalleryBrowser(
            title: "Vault",
            initialQuery: GalleryQuery(collection: .allMedia),
            allowsImport: true
        )
    }
}
