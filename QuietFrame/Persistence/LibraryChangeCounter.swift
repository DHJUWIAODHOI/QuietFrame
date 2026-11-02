import Observation

/// Goes up after every saved edit to media or albums, and unlike `modifiedAt` never moves backwards with the clock.
/// Galleries skip refreshing while it stays the same, so every such save must call `recordChange()`.
@MainActor
@Observable
final class LibraryChangeCounter {
    private(set) var generation = 0

    /// Callable from default arguments, which are not isolated to the main actor.
    nonisolated init() {}

    func recordChange() {
        generation &+= 1
    }
}
