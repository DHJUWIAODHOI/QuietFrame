import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import QuietFrame

@MainActor
final class ThumbnailGeneratorTests: XCTestCase {
    func testPhotoThumbnailIsByteIdenticalToTheLegacyGenerator() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.jpg")
        try Benchmark.photoJPEG(width: 1_600, height: 1_200, seed: 21).write(to: url)

        let thumbnail = try await ThumbnailGenerator().jpegThumbnail(for: url, mediaType: .photo, maximumPixelSize: 720)
        let legacy = try XCTUnwrap(LegacyThumbnail.photo(at: url, maximumPixelSize: 720))

        XCTAssertEqual(thumbnail, legacy)
    }

    func testLargePhotoIsScaledToTheRequestedLongestSide() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.jpg")
        try Benchmark.photoJPEG(width: 1_600, height: 1_200, seed: 22).write(to: url)

        let thumbnail = try await ThumbnailGenerator().jpegThumbnail(for: url, mediaType: .photo, maximumPixelSize: 720)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertEqual(CGImageSourceGetType(source).map { $0 as String }, UTType.jpeg.identifier)
        XCTAssertEqual(image.width, 720)
        XCTAssertEqual(image.height, 540)
    }

    func testRotatedPhotoComesOutUpright() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotated.jpg")
        try writeJPEG(Benchmark.photoJPEG(width: 400, height: 300, seed: 23), orientation: 6, to: url)

        let thumbnail = try await ThumbnailGenerator().jpegThumbnail(for: url, mediaType: .photo, maximumPixelSize: 720)
        let image = try XCTUnwrap(decodedImage(thumbnail))

        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 400)
    }

    func testVideoThumbnailMatchesTheLegacyFrame() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.mov")
        try await TestVideoWriter.writeVideo(to: url, width: 160, height: 120, frameCount: 30, framesPerSecond: 30)

        let thumbnail = try await ThumbnailGenerator().jpegThumbnail(for: url, mediaType: .video, maximumPixelSize: 720)
        let legacyFrame = try LegacyThumbnail.videoFrame(at: url, maximumPixelSize: 720)
        let legacy = try XCTUnwrap(LegacyThumbnail.jpegData(from: legacyFrame))

        let image = try XCTUnwrap(decodedImage(thumbnail))
        let legacyImage = try XCTUnwrap(decodedImage(legacy))
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 120)
        let difference = try XCTUnwrap(meanAbsoluteDifference(image, legacyImage))
        XCTAssertLessThanOrEqual(difference, 2)
    }

    func testPortraitVideoComesOutUpright() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("portrait.mov")
        try await writePortraitClip(to: url)

        let thumbnail = try await ThumbnailGenerator().jpegThumbnail(for: url, mediaType: .video, maximumPixelSize: 720)
        let image = try XCTUnwrap(decodedImage(thumbnail))
        let legacyFrame = try LegacyThumbnail.videoFrame(at: url, maximumPixelSize: 720)

        XCTAssertEqual(legacyFrame.width, 120, "The clip must carry a portrait transform for this test to mean anything")
        XCTAssertEqual(legacyFrame.height, 160)
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 160)
    }

    func testZeroSizeAndUnreadableSourcesFail() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photoURL = directory.appendingPathComponent("photo.jpg")
        try Benchmark.photoJPEG(width: 64, height: 48, seed: 24).write(to: photoURL)
        let missingURL = directory.appendingPathComponent("missing.jpg")
        let textURL = directory.appendingPathComponent("notes.txt")
        try Data("not a photo or a video".utf8).write(to: textURL)
        let cases: [(url: URL, maximumPixelSize: Int)] = [(photoURL, 0), (missingURL, 720), (textURL, 720)]
        let generator = ThumbnailGenerator()

        for mediaType in [MediaType.photo, MediaType.video] {
            for testCase in cases {
                do {
                    _ = try await generator.jpegThumbnail(
                        for: testCase.url,
                        mediaType: mediaType,
                        maximumPixelSize: testCase.maximumPixelSize
                    )
                    XCTFail("\(testCase.url.lastPathComponent) as a \(mediaType) must not give a thumbnail")
                } catch {
                    XCTAssertEqual(error as? VaultError, .thumbnailFailed, testCase.url.lastPathComponent)
                }
            }
        }
    }

    private func decodedImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writeJPEG(_ jpeg: Data, orientation: Int, to url: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// The average per-channel difference of two images of the same size, in 8-bit steps.
    private func meanAbsoluteDifference(_ first: CGImage, _ second: CGImage) -> Double? {
        guard first.width == second.width, first.height == second.height,
              let firstBytes = rgbaBytes(first), let secondBytes = rgbaBytes(second),
              !firstBytes.isEmpty else { return nil }
        var total = 0
        for index in firstBytes.indices {
            total += abs(Int(firstBytes[index]) - Int(secondBytes[index]))
        }
        return Double(total) / Double(firstBytes.count)
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// A short H.264 clip stored sideways with a portrait transform, the way a phone records portrait video.
    private func writePortraitClip(to url: URL) async throws {
        let width = 160
        let height = 120
        let frameCount = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VaultError.fileOperationFailed }
        writer.startSession(atSourceTime: .zero)
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw VaultError.fileOperationFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw VaultError.fileOperationFailed }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32(40 + frameIndex * 20), CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: 10)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? VaultError.fileOperationFailed
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: 10))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VaultError.fileOperationFailed }
    }
}

/// The thumbnail code as it was before photo thumbnails moved to a dispatch queue and video frames to the
/// asynchronous generator; new output is compared against it.
private enum LegacyThumbnail {
    static func photo(at url: URL, maximumPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ) else { return nil }
        return jpegData(from: image)
    }

    static func videoFrame(at url: URL, maximumPixelSize: Int) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        return try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
    }

    static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
