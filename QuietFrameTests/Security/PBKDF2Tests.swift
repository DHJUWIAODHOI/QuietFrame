import CryptoKit
import XCTest
@testable import QuietFrame

final class PBKDF2Tests: XCTestCase {
    func testSHA256KnownVector() throws {
        let key = try PBKDF2.deriveSHA256Key(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 1
        )
        let data = key.withUnsafeBytes { Data($0) }

        XCTAssertEqual(
            data.hexadecimalString,
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        )
    }
}
