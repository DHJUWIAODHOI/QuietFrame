import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import QuietFrame

@MainActor
final class MediaMetadataServiceTests: XCTestCase {
    func testPhotoMetadataReadsSizeCaptureDateAndType() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.jpg")
        try writeJPEG(Benchmark.photoJPEG(width: 320, height: 240, seed: 31), exifDate: "2024:05:06 07:08:09", to: url)
        let fileSize = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        var components = DateComponents()
        components.year = 2024
        components.month = 5
        components.day = 6
        components.hour = 7
        components.minute = 8
        components.second = 9
        let captureDate = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        let metadata = try await MediaMetadataService().metadata(
            for: url,
            mediaType: .photo,
            originalFilename: "IMG_0001.JPG"
        )

        XCTAssertEqual(metadata, MediaMetadata(
            mediaType: .photo,
            contentTypeIdentifier: UTType.jpeg.identifier,
            originalFilename: "IMG_0001.JPG",
            originalCreationDate: captureDate,
            pixelWidth: 320,
            pixelHeight: 240,
            duration: nil,
            byteCount: Int64(fileSize)
        ))
    }

    func testVideoMetadataReadsDurationAndSize() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.mov")
        try await TestVideoWriter.writeVideo(to: url, width: 160, height: 120, frameCount: 30, framesPerSecond: 30)
        let fileSize = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let metadata = try await MediaMetadataService().metadata(for: url, mediaType: .video, originalFilename: "clip.mov")

        let duration = try XCTUnwrap(metadata.duration)
        XCTAssertEqual(metadata.mediaType, .video)
        XCTAssertEqual(metadata.contentTypeIdentifier, UTType.quickTimeMovie.identifier)
        XCTAssertEqual(metadata.originalFilename, "clip.mov")
        XCTAssertEqual(metadata.pixelWidth, 160)
        XCTAssertEqual(metadata.pixelHeight, 120)
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        XCTAssertEqual(metadata.byteCount, Int64(fileSize))
    }

    func testEmptyAndUnreadableFilesAreUnsupported() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let emptyURL = directory.appendingPathComponent("empty.jpg")
        try Data().write(to: emptyURL)
        let textURL = directory.appendingPathComponent("notes.jpg")
        try Data("not a photo".utf8).write(to: textURL)
        let cases: [(url: URL, mediaType: MediaType)] = [(emptyURL, .photo), (emptyURL, .video), (textURL, .photo)]
        let reader = MediaMetadataService()

        for testCase in cases {
            do {
                _ = try await reader.metadata(for: testCase.url, mediaType: testCase.mediaType, originalFilename: nil)
                XCTFail("\(testCase.url.lastPathComponent) as a \(testCase.mediaType) must be rejected")
            } catch {
                XCTAssertEqual(error as? VaultError, .unsupportedFileType, testCase.url.lastPathComponent)
            }
        }
    }

    private func writeJPEG(_ jpeg: Data, exifDate: String, to url: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let properties = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
