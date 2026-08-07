import SwiftUI

struct EmptyVaultView: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(QuietFrameTheme.vaultGradient)
                    .frame(width: 116, height: 116)
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("A quieter camera roll")
                    .font(.title2.weight(.semibold))
                Text("Choose photos and videos to protect. Your media stays encrypted on this device.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            Button(action: action) {
                Label("Choose Media", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("choose-media")
        }
        .padding(QuietFrameTheme.pagePadding)
    }
}
