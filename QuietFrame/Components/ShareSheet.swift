import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.completeOnce()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIActivityViewController, coordinator: Coordinator) {
        coordinator.completeOnce()
    }

    final class Coordinator {
        private var didComplete = false
        private let completion: () -> Void

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func completeOnce() {
            guard !didComplete else { return }
            didComplete = true
            completion()
        }
    }
}
