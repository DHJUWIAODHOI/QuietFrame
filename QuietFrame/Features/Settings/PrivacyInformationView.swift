import SwiftUI

struct PrivacyInformationView: View {
    var body: some View {
        List {
            Section {
                QuietIntroduction(
                    title: "Private by construction",
                    message: "QuietFrame has no account system, analytics SDK, advertising SDK, cloud service, or external media server. Your vault remains in this app's sandbox on this device.",
                    systemImage: "hand.raised.square.fill"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, QuietFrameTheme.contentSpacing)
                .listRowBackground(Color.clear)
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
        .listStyle(.insetGrouped)
        .listSectionSpacing(QuietFrameTheme.sectionSpacing)
        .labelStyle(QuietSettingsLabelStyle())
        .quietFormStyle()
        .frame(maxWidth: QuietFrameTheme.readableWidth + 2 * QuietFrameTheme.pagePadding)
        .frame(maxWidth: .infinity)
        .background(QuietFrameTheme.background)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyRow(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: QuietFrameTheme.compactSpacing) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
            }
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, QuietFrameTheme.contentSpacing)
        .accessibilityElement(children: .combine)
    }
}
