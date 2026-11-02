import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ThumbnailGenerating: Sendable {
    func jpegThumbnail(for url: URL, mediaType: MediaType, maximumPixelSize: Int) async throws -> Data
}

actor ThumbnailGenerator: ThumbnailGenerating {
    nonisolated func jpegThumbnail(
        for url: URL,
        mediaType: MediaType,
        maximumPixelSize: Int = 720
    ) async throws -> Data {
        guard maximumPixelSize > 0 else { throw VaultError.thumbnailFailed }
        let image: CGImage
        switch mediaType {
        case .photo:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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
            image = thumbnail
        case .video:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
            do {
                image = try generator.copyCGImage(
                    at: CMTime(seconds: 0.1, preferredTimescale: 600),
                    actualTime: nil
                )
            } catch {
                throw VaultError.thumbnailFailed
            }
        }

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
