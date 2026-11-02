import SwiftData
@testable import QuietFrame

extension VaultAlbum {
    /// Counts in memory, as album rows did before `AlbumCounts` asked the store; tests and benchmarks compare with it.
    var activeMediaCount: Int {
        media.lazy.filter { !$0.isTrashed }.count
    }
}
