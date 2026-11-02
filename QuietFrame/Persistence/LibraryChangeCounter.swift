import Observation

/// Goes up after every saved edit to media or albums. Unlike `modifiedAt`, it never moves backwards with the clock,
/// so screens and caches that depend on the library can tell reliably when it changed.
@MainActor
@Observable
final class LibraryChangeCounter {
    private(set) var generation = 0

    func recordChange() {
        generation &+= 1
    }
}
