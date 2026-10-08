import SwiftUI

struct UnlockView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var passcode = ""
    @State private var attemptedBiometrics = false
    @State private var currentDate = Date()
    @State private var confirmsForgottenPasscode = false
    @State private var showsRecoveryReset = false

    var body: some View {
        AuthenticationLayout { isCompactHeight in
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Text("QuietFrame")
                    .font(QuietFrameTheme.titleFont)
                    .foregroundStyle(QuietFrameTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Enter your passcode to continue")
                    .font(.subheadline)
                    .foregroundStyle(QuietFrameTheme.quietInk)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, QuietFrameTheme.pagePadding)

            SixDigitPasscodeField(
                label: "Six-digit QuietFrame passcode",
                passcode: $passcode,
                isDisabled: coordinator.isWorking || isLockedOut,
                irisSize: irisSize(isCompactHeight: isCompactHeight)
            ) {
                Task {
                    await coordinator.unlock(passcode: passcode)
                    if coordinator.state != .unlocked { passcode = "" }
                }
            }

            statusMessage

            VStack(spacing: 4) {
                if coordinator.biometricsEnabled, coordinator.biometricKind != .none {
                    Button {
                        Task { await coordinator.unlockWithBiometrics() }
                    } label: {
                        Label(coordinator.biometricButtonTitle, systemImage: biometricSymbol)
                    }
                    .buttonStyle(ApertureButtonStyle(kind: .secondary, fillsWidth: false))
                    .disabled(coordinator.isWorking)
                    .accessibilityIdentifier("biometric-unlock")
                }

                Button {
                    confirmsForgottenPasscode = true
                } label: {
                    Text("Forgot passcode?")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(QuietFrameTheme.quietInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, QuietFrameTheme.contentSpacing)
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, QuietFrameTheme.contentSpacing)

            Spacer(minLength: QuietFrameTheme.contentSpacing)

            encryptionFooter
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
            Button("Erase vault and start over", role: .destructive) { showsRecoveryReset = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The passcode cannot be recovered. Starting over permanently erases encrypted media and keys after device-owner authentication.")
        }
        .sheet(isPresented: $showsRecoveryReset) {
            RecoveryResetView(coordinator: coordinator)
        }
        .accessibilityIdentifier("unlock-screen")
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let lockoutDate = coordinator.lockoutDate, lockoutDate > Date() {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Label {
                    Text(lockoutText(at: context.date, until: lockoutDate))
                        .foregroundStyle(QuietFrameTheme.ink)
                } icon: {
                    Image(systemName: "clock")
                        .foregroundStyle(QuietFrameTheme.quietInk)
                        .accessibilityHidden(true)
                }
                .font(.callout.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
                .padding(QuietFrameTheme.contentSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .quietCard()
            }
            .padding(.top, QuietFrameTheme.contentSpacing)
        } else if let message = coordinator.userMessage {
            AuthenticationErrorMessage(message: message)
                .padding(QuietFrameTheme.contentSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .quietCard()
                .accessibilityLabel("Error: \(message)")
                .padding(.top, QuietFrameTheme.contentSpacing)
        }
    }

    private var encryptionFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text("Media remains encrypted on this device")
        }
        .font(.footnote)
        .foregroundStyle(QuietFrameTheme.quietInk)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func irisSize(isCompactHeight: Bool) -> CGFloat {
        if isCompactHeight { return 120 }
        return dynamicTypeSize.isAccessibilitySize ? 128 : 176
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
