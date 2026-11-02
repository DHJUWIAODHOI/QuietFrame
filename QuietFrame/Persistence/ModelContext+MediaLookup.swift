import Foundation
import SwiftData

extension ModelContext {
    /// Keeps each statement well under SQLite's limit on bound values.
    private static let mediaLookupBatchSize = 500

    func fetchMedia(ids: some Sequence<UUID>) throws -> [VaultMedia] {
        let uniqueIDs = Array(Set(ids))
        var media: [VaultMedia] = []
        media.reserveCapacity(uniqueIDs.count)
        var start = 0
        while start < uniqueIDs.count {
            let end = min(start + Self.mediaLookupBatchSize, uniqueIDs.count)
            let batch = Array(uniqueIDs[start..<end])
            media += try fetch(FetchDescriptor<VaultMedia>(predicate: #Predicate { batch.contains($0.id) }))
            start = end
        }
        return media
    }
}
