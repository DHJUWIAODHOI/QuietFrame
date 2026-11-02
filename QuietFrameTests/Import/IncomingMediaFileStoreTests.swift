import XCTest
@testable import QuietFrame

@MainActor
final class IncomingMediaFileStoreTests: XCTestCase {
    func testBackgroundRemovalDeletesOnlyIncomingCopies() async throws {
        let directory = try Benchmark.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incoming = directory.appendingPathComponent("QuietFrameIncoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("keep.jpg")
        let copies = (0..<3).map { incoming.appendingPathComponent("copy-\($0).jpg") }
        for url in [outside] + copies {
            try Data("plaintext".utf8).write(to: url)
        }

        IncomingMediaFileStore.removeInBackground([outside] + copies)

        let deadline = Date().addingTimeInterval(10)
        while copies.contains(where: { FileManager.default.fileExists(atPath: $0.path) }), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(copies.contains { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Only files in the incoming folder are removed")
    }
}
