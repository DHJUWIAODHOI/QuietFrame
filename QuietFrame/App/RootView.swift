import SwiftData
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        switch appModel.bootstrapState {
        case .loading:
            LaunchView()
        case .ready(let dependencies):
            AuthenticatedRootView(dependencies: dependencies)
                .modelContainer(dependencies.modelContainer)
                .environment(dependencies)
        case .failed(let message):
            VaultProblemView(
                title: "Vault unavailable",
                message: message,
                systemImage: "externaldrive.badge.exclamationmark"
            ) {
                Button("Try again") { Task { await appModel.retryBootstrap() } }
                    .buttonStyle(.aperturePrimary)
            }
            .accessibilityIdentifier("migration-error")
        }
    }
}

/// A calm full-screen explanation for states where the vault cannot open, with one way forward.
private struct VaultProblemView<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: QuietFrameTheme.sectionSpacing) {
            Spacer(minLength: 0)
            VStack(spacing: QuietFrameTheme.contentSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(QuietFrameTheme.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(QuietFrameTheme.titleFont)
                    .foregroundStyle(QuietFrameTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(QuietFrameTheme.quietInk)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            actions
            Spacer(minLength: 0)
        }
        .frame(maxWidth: QuietFrameTheme.readableWidth)
        .padding(QuietFrameTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuietFrameTheme.background.ignoresSafeArea())
    }
}

private struct AuthenticatedRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneIsObscured = true
    @State private var screenIsCaptured = false
    @State private var lifecycleTask: Task<Void, Never>?

    let dependencies: AppDependencies

    private var coordinator: VaultLockCoordinator { dependencies.lockCoordinator }

    var body: some View {
        ZStack {
            protectedContent
                .allowsHitTesting(!isShielded)
                .accessibilityHidden(isShielded)

            if isShielded {
                PrivacyShieldView(isScreenCaptured: screenIsCaptured)
                    .zIndex(100)
            }
        }
        .background {
            PrivacyShieldWindow(isVisible: isShielded, captureStateDidChange: updateCaptureState)
        }
        .background(QuietFrameTheme.background.ignoresSafeArea())
        .task {
            await coordinator.initializeIfNeeded()
            await handle(scenePhase)
            await dependencies.mediaImportService.cleanupAbandonedIncomingFiles()
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue != .active { sceneIsObscured = true }
            lifecycleTask?.cancel()
            lifecycleTask = Task { await handle(newValue) }
        }
        .onChange(of: coordinator.state) { _, newState in
            if newState != .unlocked {
                dependencies.thumbnailService.clearCache()
            }
        }
    }

    @ViewBuilder
    private var protectedContent: some View {
        switch coordinator.state {
        case .loading:
            LaunchView()
        case .needsOnboarding:
            OnboardingView(coordinator: coordinator)
        case .locked:
            if coordinator.authenticationMode == .none {
                LaunchView()
            } else {
                UnlockView(coordinator: coordinator)
            }
        case .unlocked:
            MainTabView()
        case .retryRequired:
            RetryRequiredView(coordinator: coordinator)
        case .recoveryRequired:
            RecoveryRequiredView(coordinator: coordinator, message: coordinator.userMessage)
        }
    }

    private var isShielded: Bool {
        sceneIsObscured || screenIsCaptured
    }

    private func handle(_ phase: ScenePhase) async {
        if phase == .active, screenIsCaptured {
            await coordinator.lock()
            return
        }

        let event: AppLifecycleEvent
        switch phase {
        case .active: event = .active
        case .inactive: event = .inactive
        case .background: event = .background
        @unknown default: event = .inactive
        }
        await coordinator.handleLifecycle(event)
        guard phase == .active else { return }
        guard scenePhase == .active, !screenIsCaptured else {
            await coordinator.lock()
            return
        }
        sceneIsObscured = false
    }

    private func updateCaptureState(_ isCaptured: Bool) {
        let wasCaptured = screenIsCaptured
        screenIsCaptured = isCaptured
        lifecycleTask?.cancel()
        if isCaptured {
            lifecycleTask = Task { await coordinator.lock() }
        } else if wasCaptured {
            lifecycleTask = Task {
                if scenePhase == .active {
                    await handle(.active)
                }
            }
        }
    }

}

private struct RetryRequiredView: View {
    let coordinator: VaultLockCoordinator

    var body: some View {
        VaultProblemView(
            title: "QuietFrame couldn't open",
            message: coordinator.userMessage ?? "Try opening the vault again.",
            systemImage: "arrow.clockwise.circle"
        ) {
            Button("Try again") { Task { await coordinator.retryOpeningVault() } }
                .buttonStyle(.aperturePrimary)
        }
        .accessibilityIdentifier("vault-retry-required")
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            // Opaque launch cover; must stay opaque for privacy.
            QuietFrameTheme.vaultGradient.ignoresSafeArea()
            VStack(spacing: QuietFrameTheme.sectionSpacing) {
                ApertureMark(closure: 1, filledBlades: 6, size: 120)
                Text("QuietFrame")
                    .font(QuietFrameTheme.titleFont)
                    .foregroundStyle(QuietFrameTheme.ink)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("QuietFrame is opening")
        .accessibilityIdentifier("launch")
    }
}

private struct RecoveryRequiredView: View {
    let coordinator: VaultLockCoordinator
    let message: String?
    @State private var showsReset = false

    var body: some View {
        VaultProblemView(
            title: "Encryption key unavailable",
            message: message ?? "QuietFrame cannot safely open the existing vault.",
            systemImage: "key.slash"
        ) {
            Button("Erase unrecoverable vault", role: .destructive) { showsReset = true }
                .buttonStyle(.apertureDestructive)
        }
        .sheet(isPresented: $showsReset) {
            RecoveryResetView(coordinator: coordinator)
        }
        .accessibilityIdentifier("key-recovery-required")
    }
}
