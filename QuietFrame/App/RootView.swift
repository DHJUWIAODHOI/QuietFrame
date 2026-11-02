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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sceneIsObscured = true
    @State private var screenIsCaptured = false
    @State private var lifecycleTask: Task<Void, Never>?
    @State private var irisSnapshot: PasscodeIrisSnapshot?
    @State private var unlockFlourish: UnlockFlourish?
    @State private var isFinishingOnboarding = false

    let dependencies: AppDependencies

    private var coordinator: VaultLockCoordinator { dependencies.lockCoordinator }

    var body: some View {
        ZStack {
            protectedContent
                .allowsHitTesting(!isShielded)
                .accessibilityHidden(isShielded)

            if let flourish = unlockFlourish {
                UnlockIrisFlourish(snapshot: flourish.snapshot) {
                    finishUnlockFlourish(flourish.id)
                }
                .id(flourish.id)
                .zIndex(50)
            }

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
                dependencies.repository.clearSearchSnapshot()
            }
        }
        .onPreferenceChange(PasscodeIrisPreferenceKey.self) { snapshot in
            guard coordinator.state != .unlocked else { return }
            irisSnapshot = snapshot
        }
        .onChange(of: coordinator.state) { oldState, newState in
            if newState == .unlocked {
                beginUnlockFlourish(isFirstOpen: oldState == .needsOnboarding || isFinishingOnboarding)
            } else {
                unlockFlourish = nil
            }
            isFinishingOnboarding = oldState == .needsOnboarding && newState == .locked
        }
        .onChange(of: coordinator.isWorking) { _, isWorking in
            if !isWorking, coordinator.state == .locked { isFinishingOnboarding = false }
        }
    }

    @ViewBuilder
    private var protectedContent: some View {
        switch coordinator.state {
        case .loading:
            LaunchView()
                .transition(gateTransition)
        case .needsOnboarding:
            OnboardingView(coordinator: coordinator)
                .transition(gateTransition)
        case .locked:
            if coordinator.authenticationMode == .none {
                LaunchView()
                    .transition(lockedTransition)
            } else {
                UnlockView(coordinator: coordinator)
                    .transition(lockedTransition)
            }
        case .unlocked:
            MainTabView()
                .transition(vaultTransition)
        case .retryRequired:
            RetryRequiredView(coordinator: coordinator)
        case .recoveryRequired:
            RecoveryRequiredView(coordinator: coordinator, message: coordinator.userMessage)
        }
    }

    private var isShielded: Bool {
        sceneIsObscured || screenIsCaptured
    }

    private var vaultTransition: AnyTransition {
        guard !reduceMotion else {
            return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)), removal: .identity)
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97))
                .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.32).delay(0.08)),
            removal: .identity
        )
    }

    private var gateTransition: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .opacity.animation(.easeOut(duration: reduceMotion ? 0.2 : 0.16))
        )
    }

    private var lockedTransition: AnyTransition {
        isFinishingOnboarding ? .identity : gateTransition
    }

    private func beginUnlockFlourish(isFirstOpen: Bool) {
        if !reduceMotion, !isFirstOpen, let irisSnapshot {
            unlockFlourish = UnlockFlourish(snapshot: irisSnapshot)
        }
        irisSnapshot = nil
    }

    private func finishUnlockFlourish(_ id: UUID) {
        if unlockFlourish?.id == id { unlockFlourish = nil }
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

private struct UnlockFlourish: Identifiable {
    let id = UUID()
    let snapshot: PasscodeIrisSnapshot
}

/// The passcode iris lifted out of the unlock screen as it opens onto the vault.
private struct UnlockIrisFlourish: View {
    let snapshot: PasscodeIrisSnapshot
    let onFinish: () -> Void
    @State private var isOpen = false

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ApertureIris(
                closure: isOpen ? 0 : startClosure,
                filledBlades: startFilledBlades,
                size: snapshot.size
            )
            .scaleEffect(isOpen ? 1.4 : 1)
            .rotationEffect(.degrees(isOpen ? 35 : 0))
            .opacity(isOpen ? 0 : 1)
            .position(x: snapshot.frame.midX - origin.x, y: snapshot.frame.midY - origin.y)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.42)) {
                isOpen = true
            } completion: {
                onFinish()
            }
        }
    }

    private var isSealed: Bool {
        snapshot.filledBlades >= 6
    }

    private var startClosure: CGFloat {
        isSealed ? 1 : snapshot.closure
    }

    private var startFilledBlades: Int {
        isSealed ? 6 : snapshot.filledBlades
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
