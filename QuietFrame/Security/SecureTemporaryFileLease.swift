import Foundation

final class SecureTemporaryFileLease: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL

    private let lock = NSLock()
    private var isCleaned = false
    private let cleanupAction: @Sendable (URL) -> Void

    init(url: URL, cleanupAction: @escaping @Sendable (URL) -> Void) {
        self.url = url
        self.cleanupAction = cleanupAction
    }

    func cleanup() {
        lock.lock()
        guard !isCleaned else {
            lock.unlock()
            return
        }
        isCleaned = true
        lock.unlock()
        cleanupAction(url)
    }

    deinit {
        cleanup()
    }
}
