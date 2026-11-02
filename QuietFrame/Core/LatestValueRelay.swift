import Foundation

/// Hands values from background work to the main actor without making the sender wait. While the main actor is busy,
/// only the newest value waits to be applied, so a slow screen never slows the work that reports to it.
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

    func send(_ value: Value) {
        continuation.yield(value)
    }

    /// Applies the last value sent, then stops.
    func finish() async {
        continuation.finish()
        await applying.value
    }
}
