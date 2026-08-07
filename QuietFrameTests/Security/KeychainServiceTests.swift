import XCTest
@testable import QuietFrame

final class KeychainServiceTests: XCTestCase {
    func testSetUpdateReadAndDelete() throws {
        let serviceName = "com.quietframe.tests.\(UUID().uuidString)"
        let keychain = KeychainService(service: serviceName)
        let account = "test-secret"
        addTeardownBlock {
            try keychain.delete(account: account)
        }

        try keychain.set(Data([1, 2, 3]), account: account)
        XCTAssertEqual(try keychain.data(for: account), Data([1, 2, 3]))

        try keychain.set(Data([4, 5]), account: account)
        XCTAssertEqual(try keychain.data(for: account), Data([4, 5]))

        try keychain.delete(account: account)
        XCTAssertNil(try keychain.data(for: account))
    }
}
