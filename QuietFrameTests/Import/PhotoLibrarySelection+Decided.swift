import Foundation
@testable import QuietFrame

extension PhotoLibrarySelection {
    /// A selection whose deletion eligibility is already decided, so preparing it never asks PhotoKit.
    init(
        itemProvider: NSItemProvider,
        typeIdentifier: String,
        mediaType: MediaType,
        originalFilename: String?,
        sourceLocalIdentifier: String?
    ) {
        self.init(
            itemProvider: itemProvider,
            typeIdentifier: typeIdentifier,
            mediaType: mediaType,
            originalFilename: originalFilename,
            deletionCheck: .resolved(sourceLocalIdentifier)
        )
    }
}
