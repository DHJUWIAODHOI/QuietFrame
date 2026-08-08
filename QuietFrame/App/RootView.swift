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
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Vault Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(message)
                )
                Button("Try Again") { Task { await appModel.retryBootstrap() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .accessibilityIdentifier("migration-error")
        }
    }
}

private struct AuthenticatedRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var settingsRecords: [AppSettings]
    @State private var sceneIsObscured = true
    @State private var screenIsCaptured = UIScreen.main.isCaptured
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
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: sceneIsObscured)
        .preferredColorScheme(preferredColorScheme)
        .task {
            await coordinator.initializeIfNeeded()
            await dependencies.mediaImportService.cleanupAbandonedIncomingFiles()
            await handle(scenePhase)
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
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            let isCaptured = UIScreen.main.isCaptured
            if isCaptured {
                screenIsCaptured = true
                Task { await coordinator.lock() }
            } else {
                Task {
                    await coordinator.resumeWithoutPasscodeIfNeeded()
                    screenIsCaptured = false
                }
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
        case .recoveryRequired:
            RecoveryRequiredView(coordinator: coordinator, message: coordinator.userMessage)
        }
    }

    private var isShielded: Bool {
        sceneIsObscured || screenIsCaptured
    }

    private func handle(_ phase: ScenePhase) async {
        let event: AppLifecycleEvent
        switch phase {
        case .active: event = .active
        case .inactive: event = .inactive
        case .background: event = .background
        @unknown default: event = .inactive
        }
        await coordinator.handleLifecycle(event)
        if phase == .active { sceneIsObscured = false }
    }

    private var preferredColorScheme: ColorScheme? {
        switch settingsRecords.first?.appearance ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            QuietFrameTheme.vaultGradient.ignoresSafeArea()
            VStack(spacing: 16) {
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
    }
}

private struct RecoveryRequiredView: View {
    let coordinator: VaultLockCoordinator
    let message: String?
    @State private var showsReset = false

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Encryption Key Unavailable",
                systemImage: "key.slash",
                description: Text(message ?? "QuietFrame cannot safely open the existing vault.")
            )
            Button("Erase Unrecoverable Vault", role: .destructive) { showsReset = true }
                .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showsReset) {
            RecoveryResetView(coordinator: coordinator)
        }
        .accessibilityIdentifier("key-recovery-required")
    }
}
