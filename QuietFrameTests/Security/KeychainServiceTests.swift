import Security
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

        // KeychainService maps every failure to keychainFailure; surface the raw status
        // (for example errSecMissingEntitlement, -34018, in an unsigned test host).
        let probeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "probe"
        ]
        var probeItem = probeQuery
        probeItem[kSecValueData as String] = Data([0])
        let probeStatus = SecItemAdd(probeItem as CFDictionary, nil)
        _ = SecItemDelete(probeQuery as CFDictionary)
        XCTAssertEqual(probeStatus, errSecSuccess, "SecItemAdd returned OSStatus \(probeStatus)")

        try keychain.set(Data([1, 2, 3]), account: account)
        XCTAssertEqual(try keychain.data(for: account), Data([1, 2, 3]))

        try keychain.set(Data([4, 5]), account: account)
        XCTAssertEqual(try keychain.data(for: account), Data([4, 5]))

        try keychain.delete(account: account)
        XCTAssertNil(try keychain.data(for: account))
    }
}
