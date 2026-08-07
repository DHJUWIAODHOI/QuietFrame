import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol MediaMetadataReading: Sendable {
    func metadata(
        for url: URL,
        mediaType: MediaType,
        originalFilename: String?
    ) async throws -> MediaMetadata
}

actor MediaMetadataService: MediaMetadataReading {
    func metadata(
        for url: URL,
        mediaType: MediaType,
        originalFilename: String?
    ) async throws -> MediaMetadata {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw VaultError.unsupportedFileType
        }
        let contentType = values.contentType ?? (mediaType == .photo ? .image : .movie)

        switch mediaType {
        case .photo:
            return try photoMetadata(
                url: url,
                fileSize: fileSize,
                contentType: contentType,
                originalFilename: originalFilename
            )
        case .video:
            return try await videoMetadata(
                url: url,
                fileSize: fileSize,
                contentType: contentType,
                originalFilename: originalFilename
            )
        }
    }

    private func photoMetadata(
        url: URL,
        fileSize: Int,
        contentType: UTType,
        originalFilename: String?
    ) throws -> MediaMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw VaultError.unsupportedFileType
        }

        return MediaMetadata(
            mediaType: .photo,
            contentTypeIdentifier: contentType.identifier,
            originalFilename: originalFilename,
            originalCreationDate: imageCreationDate(properties: properties),
            pixelWidth: width.intValue,
            pixelHeight: height.intValue,
            duration: nil,
            byteCount: Int64(fileSize)
        )
    }

    private func videoMetadata(
        url: URL,
        fileSize: Int,
        contentType: UTType,
        originalFilename: String?
    ) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric else { throw VaultError.unsupportedFileType }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VaultError.unsupportedFileType }
        async let naturalSize = track.load(.naturalSize)
        async let preferredTransform = track.load(.preferredTransform)
        let (loadedSize, loadedTransform) = try await (naturalSize, preferredTransform)
        let transformedSize = loadedSize.applying(loadedTransform)
        let commonMetadata = try? await asset.load(.commonMetadata)
        let creationDate = await videoCreationDate(from: commonMetadata ?? [])

        return MediaMetadata(
            mediaType: .video,
            contentTypeIdentifier: contentType.identifier,
            originalFilename: originalFilename,
            originalCreationDate: creationDate,
            pixelWidth: Int(abs(transformedSize.width.rounded())),
            pixelHeight: Int(abs(transformedSize.height.rounded())),
            duration: max(0, duration.seconds),
            byteCount: Int64(fileSize)
        )
    }

    private func imageCreationDate(properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exifDate = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let tiffDate = tiff?[kCGImagePropertyTIFFDateTime] as? String
        let value = exifDate ?? tiffDate
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func videoCreationDate(from metadata: [AVMetadataItem]) async -> Date? {
        let matches = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierCreationDate
        )
        guard let item = matches.first else { return nil }
        return try? await item.load(.dateValue)
    }
}
