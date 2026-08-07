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
        ZStack {
            QuietFrameTheme.vaultGradient.ignoresSafeArea()
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 30) {
                        Spacer(minLength: 24)
                        Image(systemName: "viewfinder.circle.fill")
                            .font(.system(size: 58, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                        VStack(spacing: 8) {
                            Text("QuietFrame")
                                .font(.largeTitle.weight(.bold))
                            Text("Enter your passcode to continue")
                                .foregroundStyle(.white.opacity(0.72))
                        }
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
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .disabled(coordinator.isWorking)
                            .accessibilityIdentifier("biometric-unlock")
                        }

                        if let lockoutDate = coordinator.lockoutDate, lockoutDate > Date() {
                            TimelineView(.periodic(from: Date(), by: 1)) { context in
                                Text(lockoutText(at: context.date, until: lockoutDate))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        } else if let message = coordinator.userMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.92))
                                .multilineTextAlignment(.center)
                                .accessibilityLabel("Error: \(message)")
                        }
                        Spacer(minLength: 24)
                        Button("Forgot Passcode?") {
                            confirmsForgottenPasscode = true
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        Text("Media remains encrypted on this device")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    .frame(minHeight: proxy.size.height)
                    .padding(28)
                    .foregroundStyle(.white)
                }
            }
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
