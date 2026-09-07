import SwiftUI

struct OnboardingView: View {
    enum Step {
        case privacy
        case create
        case confirm
    }

    let coordinator: VaultLockCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .privacy
    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var confirmsNoPasscode = false

    var body: some View {
        AuthenticationLayout {
            Spacer(minLength: QuietFrameTheme.contentSpacing)
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
                    withAnimation(reduceMotion ? nil : .snappy) { step = .confirm }
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
            if let message = coordinator.userMessage {
                AuthenticationErrorMessage(message: message)
                    .padding(QuietFrameTheme.contentSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quietCard()
                    .accessibilityLabel("Error: \(message)")
            }
            Spacer(minLength: QuietFrameTheme.contentSpacing)
        }
        .confirmationDialog(
            "Continue without an app passcode?",
            isPresented: $confirmsNoPasscode,
            titleVisibility: .visible
        ) {
            Button("Continue Without Passcode") {
                Task { await coordinator.createWithoutPasscode() }
            }
            Button("Use a Passcode", role: .cancel) {
                withAnimation(reduceMotion ? nil : .snappy) { step = .create }
            }
        } message: {
            Text("Your media will still be encrypted and protected by the iPhone Keychain, but anyone using your unlocked iPhone can open QuietFrame. You can add a passcode later in Settings.")
        }
        .accessibilityIdentifier("onboarding")
    }

    private var privacyStep: some View {
        VStack(spacing: QuietFrameTheme.sectionSpacing) {
            QuietIntroduction(
                title: "Your moments, held quietly.",
                message: "QuietFrame encrypts photos and videos on this device. There are no accounts, ads, analytics, or media uploads.",
                systemImage: "viewfinder.circle.fill"
            )
            VStack(alignment: .leading, spacing: QuietFrameTheme.contentSpacing) {
                privacyPoint("lock.shield.fill", "Encrypted at rest")
                Divider()
                privacyPoint("icloud.slash.fill", "Excluded from iCloud backup")
                Divider()
                privacyPoint("photo.badge.plus", "Photos access only when you choose")
            }
            .padding(QuietFrameTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .quietCard()

            VStack(spacing: QuietFrameTheme.compactSpacing) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { step = .create }
                } label: {
                    Text("Use a Passcode")
                        .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-setup")

                Button {
                    confirmsNoPasscode = true
                } label: {
                    Text("Continue Without Passcode")
                        .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("skip-passcode")
            }
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func privacyPoint(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(QuietFrameTheme.accent)
        }
        .font(.subheadline.weight(.medium))
        .labelStyle(QuietSettingsLabelStyle())
    }

    private func passcodeStep(
        title: String,
        detail: String,
        label: String,
        value: Binding<String>,
        onComplete: @escaping () -> Void
    ) -> some View {
        VStack(spacing: QuietFrameTheme.sectionSpacing) {
            QuietIntroduction(title: title, message: detail, systemImage: "lock.square.stack.fill")
            SixDigitPasscodeField(
                label: label,
                passcode: value,
                isDisabled: coordinator.isWorking,
                onComplete: onComplete
            )
            .padding(QuietFrameTheme.contentSpacing)
            .quietCard()
        }
    }
}
