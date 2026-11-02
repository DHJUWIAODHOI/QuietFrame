import Observation

/// Goes up after every saved edit to media or albums. Unlike `modifiedAt`, it never moves backwards with the clock,
/// so screens and caches that depend on the library can tell reliably when it changed. Galleries skip refreshing
/// while it stays the same, so every save that changes media or albums must call `recordChange()`.
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
