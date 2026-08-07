import SwiftUI

struct PrivacyShieldView: View {
    let isScreenCaptured: Bool

    var body: some View {
        ZStack {
            QuietFrameTheme.vaultGradient.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: isScreenCaptured ? "record.circle" : "viewfinder.circle.fill")
                    .font(.system(size: 46, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(isScreenCaptured ? "Sensitive Content Hidden" : "QuietFrame")
                    .font(.title2.weight(.semibold))
                if isScreenCaptured {
                    Text("Stop screen recording or mirroring to view your vault.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .foregroundStyle(.white)
            .padding()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(isScreenCaptured ? "Sensitive content hidden during screen capture" : "QuietFrame is locked from view")
    }
}
