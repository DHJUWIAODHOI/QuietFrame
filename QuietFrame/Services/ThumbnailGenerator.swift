import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ThumbnailGenerating: Sendable {
    func jpegThumbnail(for url: URL, mediaType: MediaType, maximumPixelSize: Int) async throws -> Data
}

struct ThumbnailGenerator: ThumbnailGenerating {
    /// ImageIO blocks its thread while decoding, so photo thumbnails never hold one of Swift's cooperative threads.
    private static let photoQueue = DispatchQueue(
        label: "com.quietframe.vault.thumbnail-generation",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func jpegThumbnail(
        for url: URL,
        mediaType: MediaType,
        maximumPixelSize: Int = 720
    ) async throws -> Data {
        guard maximumPixelSize > 0 else { throw VaultError.thumbnailFailed }
        switch mediaType {
        case .photo:
            return try await BlockingWork.run(on: ThumbnailGenerator.photoQueue) {
                try ThumbnailGenerator.photoThumbnail(at: url, maximumPixelSize: maximumPixelSize)
            }
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
            let frame: CGImage
            do {
                frame = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
            } catch {
                throw VaultError.thumbnailFailed
            }
            return try ThumbnailGenerator.jpegData(from: frame)
        }
    }

    private static func photoThumbnail(at url: URL, maximumPixelSize: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ) else {
            throw VaultError.thumbnailFailed
        }
        return try jpegData(from: thumbnail)
    }

    private static func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VaultError.thumbnailFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw VaultError.thumbnailFailed }
        return data as Data
    }
}
