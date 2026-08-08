import SwiftUI

struct PrivacyInformationView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "hand.raised.square.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                    Text("Private by construction")
                        .font(.title2.bold())
                    Text("QuietFrame has no account system, analytics SDK, advertising SDK, cloud service, or external media server. Your vault remains in this app's sandbox on this device.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            privacyRow(
                "On-Device Encryption",
                symbol: "lock.shield",
                text: "Every original and thumbnail is protected by authenticated AES-GCM encryption. The random master key is protected in the iOS Keychain."
            )
            privacyRow(
                "Photos Access",
                symbol: "photo.badge.plus",
                text: "The system picker opens only after you choose Import. QuietFrame requests Photos access at that point so it can inspect, revalidate, and optionally delete the exact originals after encryption."
            )
            privacyRow(
                "Backups and Device Lock",
                symbol: "iphone.gen3.radiowaves.left.and.right",
                text: "Vault files are excluded from iCloud backup and use complete file protection so iOS blocks file access while the device is locked."
            )
            privacyRow(
                "Screenshots and Recording",
                symbol: "rectangle.slash",
                text: "QuietFrame covers content in app-switcher snapshots and while iOS reports active screen capture. iOS does not provide a public API that can fully prevent screenshots; screenshot notification occurs only after capture."
            )
            privacyRow(
                "Exports",
                symbol: "square.and.arrow.up",
                text: "Exported media is decrypted into protected random temporary files, then deleted when the native activity completes, is cancelled, or the app locks."
            )
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyRow(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
