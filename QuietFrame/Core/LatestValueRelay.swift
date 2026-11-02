import Foundation

/// Hands values to the main actor without waiting for it, so a slow screen never slows the work that reports to it.
final class LatestValueRelay<Value: Sendable>: Sendable {
    private let continuation: AsyncStream<Value>.Continuation
    private let applying: Task<Void, Never>

    init(apply: @escaping @MainActor (Value) -> Void) {
        let (values, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        applying = Task { @MainActor in
            for await value in values {
                apply(value)
            }
        }
    }

    /// A relay dropped without `finish()` still applies its last value, and its task ends instead of waiting forever.
    deinit {
        continuation.finish()
    }

    func send(_ value: Value) {
        continuation.yield(value)
    }

    func finish() async {
        continuation.finish()
        await applying.value
    }
}
