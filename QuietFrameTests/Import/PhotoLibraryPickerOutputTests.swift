import UniformTypeIdentifiers
import XCTest
@testable import QuietFrame

@MainActor
final class PhotoLibraryPickerOutputTests: XCTestCase {
    func testOutputKeepsPickOrderAndCountsUnsupportedItems() throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = try photoProvider(in: directory, named: "photo.jpg")
        let text = NSItemProvider(object: "notes" as NSString)
        let video = videoProvider(named: "clip.mov")

        let output = PhotoLibraryPickerOutput(
            picked: [
                PhotoLibraryPickedItem(provider: photo, assetIdentifier: "p1"),
                PhotoLibraryPickedItem(provider: text, assetIdentifier: "t1"),
                PhotoLibraryPickedItem(provider: video, assetIdentifier: "v1")
            ],
            allowsOriginalDeletion: false
        )

        XCTAssertEqual(output.pickerFailureCount, 1)
        XCTAssertEqual(output.selections.map(\.mediaType), [.photo, .video])
        XCTAssertEqual(output.selections.map(\.typeIdentifier), [UTType.image.identifier, UTType.movie.identifier])
        XCTAssertEqual(output.selections.map(\.originalFilename), [photo.suggestedName, video.suggestedName])
        XCTAssertTrue(output.selections[0].itemProvider === photo)
        XCTAssertTrue(output.selections[1].itemProvider === video)
    }

    func testDeniedAccessDecidesEveryItemWithoutPhotoKit() throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = PhotoLibraryPickerOutput(
            picked: [
                PhotoLibraryPickedItem(provider: try photoProvider(in: directory, named: "photo.jpg"), assetIdentifier: "p1"),
                PhotoLibraryPickedItem(provider: videoProvider(named: "clip.mov"), assetIdentifier: "v1")
            ],
            allowsOriginalDeletion: false
        )

        XCTAssertEqual(output.selections.map(\.deletionCheck), [.resolved(nil), .resolved(nil)])
        XCTAssertFalse(output.selections.contains { $0.deletionCheck.needsPhotoLibrary })
    }

    func testAllowedAccessRecordsTheIdentifierAndLivePhotoFlag() throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let livePhoto = try photoProvider(in: directory, named: "live.jpg")
        livePhoto.registerDataRepresentation(forTypeIdentifier: UTType.livePhoto.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }

        let output = PhotoLibraryPickerOutput(
            picked: [
                PhotoLibraryPickedItem(provider: try photoProvider(in: directory, named: "photo.jpg"), assetIdentifier: "p1"),
                PhotoLibraryPickedItem(provider: livePhoto, assetIdentifier: "l1"),
                PhotoLibraryPickedItem(provider: videoProvider(named: "clip.mov"), assetIdentifier: nil)
            ],
            allowsOriginalDeletion: true
        )

        XCTAssertEqual(output.selections.map(\.mediaType), [.photo, .photo, .video])
        XCTAssertEqual(output.selections.map(\.deletionCheck), [
            .pending(assetIdentifier: "p1", providerHasLivePhoto: false),
            .pending(assetIdentifier: "l1", providerHasLivePhoto: true),
            .pending(assetIdentifier: nil, providerHasLivePhoto: false)
        ])
    }

    private func photoProvider(in directory: URL, named name: String) throws -> NSItemProvider {
        let url = directory.appendingPathComponent(name)
        try Benchmark.photoJPEG(width: 64, height: 48, seed: 7).write(to: url)
        return try XCTUnwrap(NSItemProvider(contentsOf: url))
    }

    private func videoProvider(named name: String) -> NSItemProvider {
        let provider = NSItemProvider(item: Data() as NSData, typeIdentifier: UTType.quickTimeMovie.identifier)
        provider.suggestedName = name
        return provider
    }
}
