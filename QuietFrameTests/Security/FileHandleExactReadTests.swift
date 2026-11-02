import Foundation
import XCTest
@testable import QuietFrame

/// Every container read goes through `readExactly`; the header decoder indexes its result from zero.
@MainActor
final class FileHandleExactReadTests: XCTestCase {
    func testConsecutiveReadsReturnExactBytesFromTheCurrentOffset() throws {
        let bytes = Data((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let file = try TemporaryFile(contents: bytes)
        defer { file.remove() }

        let first = try file.handle.readExactly(100)
        let second = try file.handle.readExactly(150)

        XCTAssertEqual(first, bytes[0..<100])
        XCTAssertEqual(second, bytes[100..<250])
        XCTAssertEqual(first.startIndex, 0)
        XCTAssertEqual(second.startIndex, 0)
        XCTAssertEqual(try file.handle.offset(), 250)
    }

    func testZeroCountReturnsNothingAndKeepsTheOffset() throws {
        let file = try TemporaryFile(contents: Data(repeating: 0x07, count: 10))
        defer { file.remove() }
        _ = try file.handle.readExactly(4)

        let nothing = try file.handle.readExactly(0)

        XCTAssertTrue(nothing.isEmpty)
        XCTAssertEqual(try file.handle.offset(), 4)
    }

    func testReadingPastTheEndIsCorrupted() throws {
        let file = try TemporaryFile(contents: Data(repeating: 0x07, count: 10))
        defer { file.remove() }

        XCTAssertThrowsError(try file.handle.readExactly(11)) { error in
            XCTAssertEqual(error as? VaultError, .corruptedFile)
        }
        XCTAssertThrowsError(try file.handle.readExactly(1)) { error in
            XCTAssertEqual(error as? VaultError, .corruptedFile)
        }
    }

    func testNegativeCountIsCorrupted() throws {
        let file = try TemporaryFile(contents: Data(repeating: 0x07, count: 10))
        defer { file.remove() }

        XCTAssertThrowsError(try file.handle.readExactly(-1)) { error in
            XCTAssertEqual(error as? VaultError, .corruptedFile)
        }
        XCTAssertEqual(try file.handle.offset(), 0)
    }

    private struct TemporaryFile {
        let url: URL
        let handle: FileHandle

        init(contents: Data) throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try contents.write(to: url)
            self.url = url
            handle = try FileHandle(forReadingFrom: url)
        }

        func remove() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }
}
