import UIKit
import XCTest
@testable import QuietFrame

@MainActor
final class ViewerPhotoLoaderTests: XCTestCase {
    func testLoadsRequestsInPriorityOrderOneAtATime() async throws {
        let storage = RecordingPhotoStorage(imageData: try makeImageData())
        let loader = ViewerPhotoLoader(storage: storage)
        let requests = (0..<3).map { _ in makeRequest() }

        loader.prepare(requests)
        try await waitUntil { requests.allSatisfy { loader.image(for: $0.mediaID) != nil } }

        let decryptedIdentifiers = await storage.decryptedIdentifiers
        let maximumConcurrentDecrypts = await storage.maximumConcurrentDecrypts
        XCTAssertEqual(decryptedIdentifiers, requests.map(\.storageIdentifier))
        XCTAssertEqual(maximumConcurrentDecrypts, 1)
    }

    func testMovingWindowReleasesPhotosOutsideIt() async throws {
        let storage = RecordingPhotoStorage(imageData: try makeImageData())
        let loader = ViewerPhotoLoader(storage: storage)
        let first = makeRequest()
        let second = makeRequest()
        let third = makeRequest()

        loader.prepare([first, second])
        try await waitUntil {
            loader.image(for: first.mediaID) != nil && loader.image(for: second.mediaID) != nil
        }
        loader.prepare([second, third])

        XCTAssertNil(loader.image(for: first.mediaID))
        XCTAssertNotNil(loader.image(for: second.mediaID))
        try await waitUntil { loader.image(for: third.mediaID) != nil }
        let decryptedIdentifiers = await storage.decryptedIdentifiers
        XCTAssertEqual(decryptedIdentifiers, [first, second, third].map(\.storageIdentifier))
    }

    func testStorageErrorIsReportedWithoutBlockingOthers() async throws {
        let broken = makeRequest()
        let healthy = makeRequest()
        let storage = RecordingPhotoStorage(
            imageData: try makeImageData(),
            failures: [broken.storageIdentifier: .insufficientStorage]
        )
        let loader = ViewerPhotoLoader(storage: storage)

        loader.prepare([broken, healthy])
        try await waitUntil {
            loader.failureMessage(for: broken.mediaID) != nil && loader.image(for: healthy.mediaID) != nil
        }

        XCTAssertNil(loader.image(for: broken.mediaID))
        XCTAssertEqual(
            loader.failureMessage(for: broken.mediaID),
            VaultError.insufficientStorage.localizedDescription
        )
    }

    func testUndecodableDataReportsCorruptedFile() async throws {
        let request = makeRequest()
        let storage = RecordingPhotoStorage(imageData: Data(repeating: 0x42, count: 64))
        let loader = ViewerPhotoLoader(storage: storage)

        loader.prepare([request])
        try await waitUntil { loader.failureMessage(for: request.mediaID) != nil }

        XCTAssertEqual(loader.failureMessage(for: request.mediaID), VaultError.corruptedFile.localizedDescription)
    }

    func testCancelledLoadKeepsItsSlotUntilItFinishes() async throws {
        let storage = GatedPhotoStorage(imageData: try makeImageData())
        let loader = ViewerPhotoLoader(storage: storage)
        let first = makeRequest()
        let second = makeRequest()

        loader.prepare([first])
        try await waitUntil { await storage.startedIdentifiers == [first.storageIdentifier] }
        loader.prepare([second])
        for _ in 0..<20 { await Task.yield() }
        let startedWhileFirstIsCancelling = await storage.startedIdentifiers
        XCTAssertEqual(startedWhileFirstIsCancelling, [first.storageIdentifier])

        await storage.release(first.storageIdentifier)
        try await waitUntil { await storage.startedIdentifiers.count == 2 }
        await storage.release(second.storageIdentifier)
        try await waitUntil { loader.image(for: second.mediaID) != nil }

        XCTAssertNil(loader.image(for: first.mediaID))
        let startedIdentifiers = await storage.startedIdentifiers
        let maximumConcurrentDecrypts = await storage.maximumConcurrentDecrypts
        let cancelledCount = await storage.cancelledCount
        XCTAssertEqual(startedIdentifiers, [first, second].map(\.storageIdentifier))
        XCTAssertEqual(maximumConcurrentDecrypts, 1)
        XCTAssertEqual(cancelledCount, 1)
    }

    func testSelectedPhotoPreemptsLoadingNeighbor() async throws {
        let storage = GatedPhotoStorage(imageData: try makeImageData())
        let loader = ViewerPhotoLoader(storage: storage)
        let previous = makeRequest()
        let selected = makeRequest()

        loader.prepare([previous, selected])
        try await waitUntil { await storage.startedIdentifiers == [previous.storageIdentifier] }
        loader.prepare([selected, previous])
        await storage.release(previous.storageIdentifier)

        try await waitUntil { await storage.startedIdentifiers.count == 2 }
        await storage.release(selected.storageIdentifier)
        try await waitUntil { loader.image(for: selected.mediaID) != nil }
        XCTAssertNil(loader.image(for: previous.mediaID))

        try await waitUntil { await storage.startedIdentifiers.count == 3 }
        await storage.release(previous.storageIdentifier)
        try await waitUntil { loader.image(for: previous.mediaID) != nil }

        let startedIdentifiers = await storage.startedIdentifiers
        let cancelledCount = await storage.cancelledCount
        XCTAssertEqual(startedIdentifiers, [previous, selected, previous].map(\.storageIdentifier))
        XCTAssertEqual(cancelledCount, 1)
    }

    func testReleaseAllDiscardsInFlightPhoto() async throws {
        let storage = GatedPhotoStorage(imageData: try makeImageData())
        let loader = ViewerPhotoLoader(storage: storage)
        let request = makeRequest()

        loader.prepare([request])
        try await waitUntil { await storage.startedIdentifiers.count == 1 }
        loader.releaseAll()
        await storage.release(request.storageIdentifier)
        try await waitUntil { !loader.isLoading }

        XCTAssertNil(loader.image(for: request.mediaID))
        XCTAssertNil(loader.failureMessage(for: request.mediaID))
        let startedIdentifiers = await storage.startedIdentifiers
        let cancelledCount = await storage.cancelledCount
        XCTAssertEqual(startedIdentifiers.count, 1)
        XCTAssertEqual(cancelledCount, 1)
    }

    func testReappearingAfterReleaseAllReloadsPhoto() async throws {
        let storage = GatedPhotoStorage(imageData: try makeImageData())
        let loader = ViewerPhotoLoader(storage: storage)
        let request = makeRequest()

        loader.prepare([request])
        try await waitUntil { await storage.startedIdentifiers.count == 1 }
        loader.releaseAll()
        loader.prepare([request])
        await storage.release(request.storageIdentifier)

        try await waitUntil { await storage.startedIdentifiers.count == 2 }
        await storage.release(request.storageIdentifier)
        try await waitUntil { loader.image(for: request.mediaID) != nil }

        let cancelledCount = await storage.cancelledCount
        XCTAssertEqual(cancelledCount, 1)
    }

    private func makeRequest() -> ViewerPhotoRequest {
        ViewerPhotoRequest(
            mediaID: UUID(),
            storageIdentifier: UUID().uuidString.lowercased(),
            location: .media
        )
    }

    private func makeImageData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the viewer photo loader.")
    }
}

private actor RecordingPhotoStorage: SecureFileStoring {
    private(set) var decryptedIdentifiers: [String] = []
    private(set) var maximumConcurrentDecrypts = 0
    private var activeDecrypts = 0
    private let imageData: Data
    private let failures: [String: VaultError]

    init(imageData: Data, failures: [String: VaultError] = [:]) {
        self.imageData = imageData
        self.failures = failures
    }

    func decryptData(
        identifier: String,
        location: EncryptedAssetLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        decryptedIdentifiers.append(identifier)
        activeDecrypts += 1
        maximumConcurrentDecrypts = max(maximumConcurrentDecrypts, activeDecrypts)
        defer { activeDecrypts -= 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        if let failure = failures[identifier] { throw failure }
        return imageData
    }

    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile {
        throw VaultError.fileOperationFailed
    }

    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile {
        throw VaultError.fileOperationFailed
    }

    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease {
        throw VaultError.fileOperationFailed
    }

    func move(identifier: String, from: EncryptedAssetLocation, to: EncryptedAssetLocation) async throws {}

    func delete(identifier: String, location: EncryptedAssetLocation) async throws {}

    func cleanupTemporaryFiles() async {}

    func removeAllEncryptedData() async throws {}

    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64 {
        0
    }

    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String> {
        []
    }
}

/// Holds each decrypt until the test releases it, then reports cancellation the way the real decrypt loop does.
private actor GatedPhotoStorage: SecureFileStoring {
    private(set) var startedIdentifiers: [String] = []
    private(set) var maximumConcurrentDecrypts = 0
    private(set) var cancelledCount = 0
    private var activeDecrypts = 0
    private var pendingDecrypts: [String: CheckedContinuation<Void, Never>] = [:]
    private let imageData: Data

    init(imageData: Data) {
        self.imageData = imageData
    }

    func release(_ identifier: String) {
        pendingDecrypts.removeValue(forKey: identifier)?.resume()
    }

    func decryptData(
        identifier: String,
        location: EncryptedAssetLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        startedIdentifiers.append(identifier)
        activeDecrypts += 1
        maximumConcurrentDecrypts = max(maximumConcurrentDecrypts, activeDecrypts)
        defer { activeDecrypts -= 1 }
        await withCheckedContinuation { continuation in
            pendingDecrypts[identifier] = continuation
        }
        if Task.isCancelled {
            cancelledCount += 1
            throw CancellationError()
        }
        return imageData
    }

    func store(
        plaintextURL: URL,
        location: EncryptedAssetLocation,
        progress: FileProgressHandler?
    ) async throws -> StoredEncryptedFile {
        throw VaultError.fileOperationFailed
    }

    func store(plaintextData: Data, location: EncryptedAssetLocation) async throws -> StoredEncryptedFile {
        throw VaultError.fileOperationFailed
    }

    func temporaryDecryptedFile(
        identifier: String,
        location: EncryptedAssetLocation,
        preferredExtension: String?
    ) async throws -> SecureTemporaryFileLease {
        throw VaultError.fileOperationFailed
    }

    func move(identifier: String, from: EncryptedAssetLocation, to: EncryptedAssetLocation) async throws {}

    func delete(identifier: String, location: EncryptedAssetLocation) async throws {}

    func cleanupTemporaryFiles() async {}

    func removeAllEncryptedData() async throws {}

    func fileByteCount(identifier: String, location: EncryptedAssetLocation) async throws -> Int64 {
        0
    }

    func allIdentifiers(location: EncryptedAssetLocation) async throws -> Set<String> {
        []
    }
}
