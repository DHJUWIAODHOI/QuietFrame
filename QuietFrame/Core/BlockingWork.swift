import Foundation

/// Runs blocking work (ImageIO, PhotoKit) on a Dispatch queue, off Swift's cooperative pool of one thread per core.
enum BlockingWork {
    static func run<Value: Sendable>(
        on queue: DispatchQueue,
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let state = BlockingWorkState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                queue.async {
                    guard !state.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let value = try work()
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class BlockingWorkState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
