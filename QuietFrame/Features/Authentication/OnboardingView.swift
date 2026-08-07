import SwiftUI

struct OnboardingView: View {
    enum Step {
        case privacy
        case create
        case confirm
    }

    let coordinator: VaultLockCoordinator
    @State private var step: Step = .privacy
    @State private var passcode = ""
    @State private var confirmation = ""

    var body: some View {
        ZStack {
            QuietFrameTheme.vaultGradient.ignoresSafeArea()
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 30) {
                        Spacer(minLength: 24)
                        switch step {
                        case .privacy:
                            privacyStep
                        case .create:
                            passcodeStep(
                                title: "Create your passcode",
                                detail: "Choose six digits you can remember. QuietFrame cannot recover a forgotten passcode.",
                                label: "New six-digit passcode",
                                value: $passcode
                            ) {
                                withAnimation(.snappy) { step = .confirm }
                            }
                        case .confirm:
                            passcodeStep(
                                title: "Confirm your passcode",
                                detail: "Enter the same six digits once more.",
                                label: "Confirm six-digit passcode",
                                value: $confirmation
                            ) {
                                Task {
                                    await coordinator.createPasscode(passcode, confirmation: confirmation)
                                    if coordinator.state != .unlocked { confirmation = "" }
                                }
                            }
                        }
                        Spacer(minLength: 24)
                        if let message = coordinator.userMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .accessibilityLabel("Error: \(message)")
                        }
                    }
                    .frame(minHeight: proxy.size.height)
                    .padding(28)
                    .foregroundStyle(.white)
                }
            }
        }
        .accessibilityIdentifier("onboarding")
    }

    private var privacyStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 64, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Your moments, held quietly.")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("QuietFrame encrypts photos and videos on this device. There are no accounts, ads, analytics, or media uploads.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                privacyPoint("lock.shield.fill", "Encrypted at rest")
                privacyPoint("icloud.slash.fill", "Excluded from iCloud backup")
                privacyPoint("photo.badge.plus", "Photos access only when you choose")
            }
            Button("Set Up QuietFrame") {
                withAnimation(.snappy) { step = .create }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .controlSize(.large)
            .accessibilityIdentifier("start-setup")
        }
    }

    private func privacyPoint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func passcodeStep(
        title: String,
        detail: String,
        label: String,
        value: Binding<String>,
        onComplete: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.square.stack.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title.weight(.bold))
                Text(detail)
                    .foregroundStyle(.white.opacity(0.74))
                    .multilineTextAlignment(.center)
            }
            SixDigitPasscodeField(
                label: label,
                passcode: value,
                isDisabled: coordinator.isWorking,
                onComplete: onComplete
            )
        }
    }
}
