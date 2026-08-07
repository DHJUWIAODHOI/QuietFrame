import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PhotoPickerTransfer: Transferable, Sendable {
    let url: URL
    let mediaType: MediaType
    let originalFilename: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try makeTransfer(from: received.file, mediaType: .photo)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try makeTransfer(from: received.file, mediaType: .video)
        }
    }

    private static func makeTransfer(from sourceURL: URL, mediaType: MediaType) throws -> PhotoPickerTransfer {
        let copiedURL = try IncomingMediaFileStore.copyProtectedFile(from: sourceURL)
        let name = sourceURL.lastPathComponent.isEmpty ? nil : sourceURL.lastPathComponent
        return PhotoPickerTransfer(url: copiedURL, mediaType: mediaType, originalFilename: name)
    }
}
