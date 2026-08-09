import SwiftUI
import UIKit

struct PrivacyShieldView: View {
    let isScreenCaptured: Bool

    var body: some View {
        ZStack {
            QuietFrameTheme.vaultGradient.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: isScreenCaptured ? "record.circle" : "viewfinder.circle.fill")
                    .font(.system(size: 46, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(isScreenCaptured ? "Sensitive Content Hidden" : "QuietFrame")
                    .font(.title2.weight(.semibold))
                if isScreenCaptured {
                    Text("Stop screen recording or mirroring to view your vault.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .foregroundStyle(.white)
            .padding()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(isScreenCaptured ? "Sensitive content hidden during screen capture" : "QuietFrame is locked from view")
    }
}

struct PrivacyShieldWindow: UIViewRepresentable {
    let isVisible: Bool
    let captureStateDidChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SceneReaderView {
        context.coordinator.update(
            isVisible: isVisible,
            captureStateDidChange: captureStateDidChange
        )
        let view = SceneReaderView()
        view.isUserInteractionEnabled = false
        view.sceneDidChange = { [weak coordinator = context.coordinator] scene in
            coordinator?.attach(to: scene)
        }
        return view
    }

    func updateUIView(_ uiView: SceneReaderView, context: Context) {
        context.coordinator.update(
            isVisible: isVisible,
            captureStateDidChange: captureStateDidChange
        )
    }

    static func dismantleUIView(_ uiView: SceneReaderView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class SceneReaderView: UIView {
        var sceneDidChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            sceneDidChange?(window?.windowScene)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scene: UIWindowScene?
        private var privacyWindow: UIWindow?
        private var hostingController: UIHostingController<PrivacyShieldView>?
        private var requestedVisibility = true
        private var captureStateDidChange: ((Bool) -> Void)?
        private var reportedCaptureState: Bool?
        private var sceneIsObscured = true

        func attach(to scene: UIWindowScene?) {
            guard self.scene !== scene else { return }
            removeWindow()
            guard let scene else { return }

            self.scene = scene
            sceneIsObscured = scene.activationState != .foregroundActive

            let hostingController = UIHostingController(
                rootView: PrivacyShieldView(isScreenCaptured: scene.screen.isCaptured)
            )

            let privacyWindow = UIWindow(windowScene: scene)
            privacyWindow.windowLevel = .alert + 1
            privacyWindow.backgroundColor = .black
            privacyWindow.rootViewController = hostingController

            self.hostingController = hostingController
            self.privacyWindow = privacyWindow

            let notifications = NotificationCenter.default
            notifications.addObserver(
                self,
                selector: #selector(sceneWillDeactivate(_:)),
                name: UIScene.willDeactivateNotification,
                object: scene
            )
            notifications.addObserver(
                self,
                selector: #selector(sceneDidActivate(_:)),
                name: UIScene.didActivateNotification,
                object: scene
            )
            notifications.addObserver(
                self,
                selector: #selector(captureStateChanged(_:)),
                name: UIScreen.capturedDidChangeNotification,
                object: scene.screen
            )
            updateWindow()
        }

        func update(isVisible: Bool, captureStateDidChange: @escaping (Bool) -> Void) {
            requestedVisibility = isVisible
            self.captureStateDidChange = captureStateDidChange
            updateWindow(reportCaptureState: false)
        }

        func detach() {
            removeWindow()
            captureStateDidChange = nil
        }

        private func removeWindow() {
            NotificationCenter.default.removeObserver(self)
            privacyWindow = nil
            hostingController = nil
            scene = nil
            reportedCaptureState = nil
        }

        @objc private func sceneWillDeactivate(_ notification: Notification) {
            sceneIsObscured = true
            updateWindow()
        }

        @objc private func sceneDidActivate(_ notification: Notification) {
            sceneIsObscured = false
            updateWindow()
        }

        @objc private func captureStateChanged(_ notification: Notification) {
            updateWindow()
        }

        private func updateWindow(reportCaptureState: Bool = true) {
            guard let scene, let privacyWindow, let hostingController else { return }
            let isCaptured = scene.screen.isCaptured
            hostingController.rootView = PrivacyShieldView(isScreenCaptured: isCaptured)
            privacyWindow.isHidden = !(requestedVisibility || sceneIsObscured || isCaptured)
            if reportCaptureState,
               let captureStateDidChange,
               reportedCaptureState != isCaptured {
                reportedCaptureState = isCaptured
                captureStateDidChange(isCaptured)
            }
        }
    }
}
