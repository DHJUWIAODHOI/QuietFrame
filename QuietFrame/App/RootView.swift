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
            VStack(spacing: QuietFrameTheme.contentSpacing) {
                ContentUnavailableView(
                    "Vault Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(message)
                )
                Button("Try Again") { Task { await appModel.retryBootstrap() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: QuietFrameTheme.readableWidth)
            .padding(QuietFrameTheme.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(QuietFrameTheme.background)
            .accessibilityIdentifier("migration-error")
        }
    }
}

private struct AuthenticatedRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settingsRecords: [AppSettings]
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
        .preferredColorScheme(preferredColorScheme)
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

    private var preferredColorScheme: ColorScheme? {
        switch settingsRecords.first?.appearance ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct RetryRequiredView: View {
    let coordinator: VaultLockCoordinator

    var body: some View {
        VStack(spacing: QuietFrameTheme.contentSpacing) {
            ContentUnavailableView(
                "QuietFrame Couldn't Open",
                systemImage: "arrow.clockwise.circle",
                description: Text(coordinator.userMessage ?? "Try opening the vault again.")
            )
            Button("Try Again") { Task { await coordinator.retryOpeningVault() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: QuietFrameTheme.readableWidth)
        .padding(QuietFrameTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuietFrameTheme.background)
        .accessibilityIdentifier("vault-retry-required")
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            // Opaque launch cover; must stay opaque for privacy.
            QuietFrameTheme.vaultGradient.ignoresSafeArea()
            VStack(spacing: QuietFrameTheme.contentSpacing) {
                Image(systemName: "viewfinder.circle.fill")
                    .font(.system(size: 54, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text("QuietFrame")
                    .font(.largeTitle.weight(.semibold))
            }
            .foregroundStyle(.white)
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
        VStack(spacing: QuietFrameTheme.contentSpacing) {
            ContentUnavailableView(
                "Encryption Key Unavailable",
                systemImage: "key.slash",
                description: Text(message ?? "QuietFrame cannot safely open the existing vault.")
            )
            Button("Erase Unrecoverable Vault", role: .destructive) { showsReset = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: QuietFrameTheme.readableWidth)
        .padding(QuietFrameTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuietFrameTheme.background)
        .sheet(isPresented: $showsReset) {
            RecoveryResetView(coordinator: coordinator)
        }
        .accessibilityIdentifier("key-recovery-required")
    }
}
