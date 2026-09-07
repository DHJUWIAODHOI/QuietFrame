import SwiftUI

struct UnlockView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var passcode = ""
    @State private var attemptedBiometrics = false
    @State private var currentDate = Date()
    @State private var confirmsForgottenPasscode = false
    @State private var showsRecoveryReset = false

    var body: some View {
        AuthenticationLayout {
            Spacer(minLength: QuietFrameTheme.contentSpacing)
            QuietIntroduction(
                title: "QuietFrame",
                message: "Enter your passcode to continue",
                systemImage: "viewfinder.circle.fill"
            )
            VStack(spacing: QuietFrameTheme.contentSpacing) {
                SixDigitPasscodeField(
                    label: "Six-digit QuietFrame passcode",
                    passcode: $passcode,
                    isDisabled: coordinator.isWorking || isLockedOut
                ) {
                    Task {
                        await coordinator.unlock(passcode: passcode)
                        if coordinator.state != .unlocked { passcode = "" }
                    }
                }

                if coordinator.biometricsEnabled, coordinator.biometricKind != .none {
                    Button {
                        Task { await coordinator.unlockWithBiometrics() }
                    } label: {
                        Label(coordinator.biometricButtonTitle, systemImage: biometricSymbol)
                            .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.isWorking)
                    .accessibilityIdentifier("biometric-unlock")
                }
            }
            .padding(QuietFrameTheme.contentSpacing)
            .quietCard()

            if let lockoutDate = coordinator.lockoutDate, lockoutDate > Date() {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Label {
                        Text(lockoutText(at: context.date, until: lockoutDate))
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .font(.callout.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(QuietFrameTheme.contentSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quietCard()
                }
            } else if let message = coordinator.userMessage {
                AuthenticationErrorMessage(message: message)
                    .padding(QuietFrameTheme.contentSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quietCard()
                    .accessibilityLabel("Error: \(message)")
            }
            Spacer(minLength: QuietFrameTheme.contentSpacing)
            VStack(spacing: QuietFrameTheme.compactSpacing) {
                Button {
                    confirmsForgottenPasscode = true
                } label: {
                    Text("Forgot Passcode?")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(QuietFrameTheme.accent)
                Text("Media remains encrypted on this device")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            guard !attemptedBiometrics,
                  coordinator.biometricsEnabled,
                  coordinator.biometricKind != .none else { return }
            attemptedBiometrics = true
            await coordinator.unlockWithBiometrics()
        }
        .task(id: coordinator.lockoutDate) {
            guard let lockoutDate = coordinator.lockoutDate,
                  lockoutDate > Date() else {
                currentDate = Date()
                coordinator.clearExpiredLockoutIfNeeded()
                return
            }
            let nanoseconds = UInt64(max(0, lockoutDate.timeIntervalSinceNow) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                currentDate = Date()
                coordinator.clearExpiredLockoutIfNeeded()
            } catch {
                return
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: coordinator.userMessage)
        .confirmationDialog(
            "Forgot your passcode?",
            isPresented: $confirmsForgottenPasscode,
            titleVisibility: .visible
        ) {
            Button("Erase Vault and Start Over", role: .destructive) { showsRecoveryReset = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The passcode cannot be recovered. Starting over permanently erases encrypted media and keys after device-owner authentication.")
        }
        .sheet(isPresented: $showsRecoveryReset) {
            RecoveryResetView(coordinator: coordinator)
        }
        .accessibilityIdentifier("unlock-screen")
    }

    private var isLockedOut: Bool {
        guard let lockoutDate = coordinator.lockoutDate else { return false }
        return lockoutDate > currentDate
    }

    private var biometricSymbol: String {
        coordinator.biometricKind == .touchID ? "touchid" : "faceid"
    }

    private func lockoutText(at date: Date, until lockoutDate: Date) -> String {
        let seconds = max(1, Int(ceil(lockoutDate.timeIntervalSince(date))))
        return "Try again in \(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
