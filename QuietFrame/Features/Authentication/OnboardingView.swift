import SwiftUI

struct OnboardingView: View {
    enum Step {
        case privacy
        case create
        case confirm
    }

    let coordinator: VaultLockCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step: Step = .privacy
    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var confirmsNoPasscode = false

    var body: some View {
        AuthenticationLayout { isCompactHeight in
            Spacer(minLength: QuietFrameTheme.compactSpacing)
            switch step {
            case .privacy:
                welcome(isCompactHeight: isCompactHeight)
            case .create:
                passcodeStep(
                    title: "Create your passcode",
                    detail: "Choose six digits you can remember. QuietFrame cannot recover a forgotten passcode.",
                    label: "New six-digit passcode",
                    value: $passcode,
                    isCompactHeight: isCompactHeight
                ) {
                    withAnimation(reduceMotion ? nil : .snappy) { step = .confirm }
                }
            case .confirm:
                passcodeStep(
                    title: "Confirm your passcode",
                    detail: "Enter the same six digits once more.",
                    label: "Confirm six-digit passcode",
                    value: $confirmation,
                    isCompactHeight: isCompactHeight
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
                    .padding(.top, QuietFrameTheme.contentSpacing)
            }
            Spacer(minLength: QuietFrameTheme.sectionSpacing)
            if step == .privacy {
                welcomeActions
            }
        }
        .confirmationDialog(
            "Continue without an app passcode?",
            isPresented: $confirmsNoPasscode,
            titleVisibility: .visible
        ) {
            Button("Continue without passcode") {
                Task { await coordinator.createWithoutPasscode() }
            }
            Button("Use a passcode", role: .cancel) {
                withAnimation(reduceMotion ? nil : .snappy) { step = .create }
            }
        } message: {
            Text("Your media will still be encrypted and protected by the iPhone Keychain, but anyone using your unlocked iPhone can open QuietFrame. You can add a passcode later in Settings.")
        }
        .accessibilityIdentifier("onboarding")
    }

    private func markSize(isCompactHeight: Bool) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize || isCompactHeight ? 120 : 176
    }

    private func irisSize(isCompactHeight: Bool) -> CGFloat {
        if isCompactHeight { return 120 }
        return dynamicTypeSize.isAccessibilitySize ? 128 : 176
    }

    private func welcome(isCompactHeight: Bool) -> some View {
        VStack(spacing: 0) {
            ApertureMark(closure: 0, filledBlades: 0, size: markSize(isCompactHeight: isCompactHeight))

            Text("Your moments,\nheld quietly.")
                .quietScreenTitle()
                .padding(.top, 32)

            Text("QuietFrame encrypts photos and videos on this device. There are no accounts, ads, analytics, or media uploads.")
                .font(.callout)
                .foregroundStyle(QuietFrameTheme.quietInk)
                .padding(.top, QuietFrameTheme.contentSpacing)

            VStack(alignment: .leading, spacing: 14) {
                privacyPoint("lock", "Encrypted at rest")
                privacyPoint("icloud.slash", "Excluded from iCloud backup")
                privacyPoint("checkmark.rectangle", "Photos access only when you choose")
            }
            .multilineTextAlignment(.leading)
            .padding(.top, QuietFrameTheme.sectionSpacing)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var welcomeActions: some View {
        VStack(spacing: QuietFrameTheme.compactSpacing) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) { step = .create }
            } label: {
                Text("Use a passcode")
            }
            .buttonStyle(.aperturePrimary)
            .accessibilityIdentifier("start-setup")

            Button {
                confirmsNoPasscode = true
            } label: {
                Text("Continue without passcode")
            }
            .buttonStyle(.apertureSecondary)
            .accessibilityIdentifier("skip-passcode")
        }
    }

    private func privacyPoint(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.subheadline)
        .labelStyle(QuietSettingsLabelStyle())
    }

    private func passcodeStep(
        title: String,
        detail: String,
        label: String,
        value: Binding<String>,
        isCompactHeight: Bool,
        onComplete: @escaping () -> Void
    ) -> some View {
        VStack(spacing: QuietFrameTheme.pagePadding) {
            VStack(spacing: QuietFrameTheme.compactSpacing) {
                Text(title)
                    .font(QuietFrameTheme.titleFont)
                    .foregroundStyle(QuietFrameTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(QuietFrameTheme.quietInk)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            SixDigitPasscodeField(
                label: label,
                passcode: value,
                isDisabled: coordinator.isWorking,
                irisSize: irisSize(isCompactHeight: isCompactHeight),
                onComplete: onComplete
            )
        }
    }
}
