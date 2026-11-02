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

    /// Published PBKDF2-HMAC-SHA256 vectors, including RFC 7914 section 11.
    func testMatchesPublishedVectors() throws {
        XCTAssertEqual(
            try derivedHex("password", "salt", iterations: 2, outputByteCount: 32),
            "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
        )
        XCTAssertEqual(
            try derivedHex("password", "salt", iterations: 4_096, outputByteCount: 32),
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
        )
        XCTAssertEqual(
            try derivedHex("passwd", "salt", iterations: 1, outputByteCount: 64),
            "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
                + "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
        )
        XCTAssertEqual(
            try derivedHex("Password", "NaCl", iterations: 80_000, outputByteCount: 64),
            "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56"
                + "a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d"
        )
        XCTAssertEqual(
            try derivedHex(
                "passwordPASSWORDpassword",
                "saltSALTsaltSALTsaltSALTsaltSALTsalt",
                iterations: 4_096,
                outputByteCount: 40
            ),
            "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9"
        )
    }

    /// A six-digit passcode at the production cost, checked against an independent implementation
    /// (Python's hashlib.pbkdf2_hmac), so passcode envelopes written by earlier versions still open.
    func testMatchesTheProductionParameters() throws {
        let key = try PBKDF2.deriveSHA256Key(
            password: Data("482916".utf8),
            salt: Data((0..<16).map { UInt8($0) }),
            iterations: AuthenticationService.Policy.production.derivationIterations
        )

        XCTAssertEqual(
            key.withUnsafeBytes { Data($0) }.hexadecimalString,
            "8a66ce9e44f86f913087dcba4a553c23c6c8b5c24367f7572c58b96d5bf79f6b"
        )
    }

    /// Compares with the pure-Swift derivation earlier versions shipped, across passwords shorter and longer than
    /// the HMAC block and output lengths that are not a whole number of blocks.
    func testMatchesThePreviousImplementation() throws {
        for (iterations, outputByteCount) in [(1, 32), (2, 16), (3, 33), (1_000, 32), (4_097, 64)] {
            for (passwordLength, saltLength) in [(1, 16), (6, 16), (6, 33), (64, 64), (65, 16), (200, 48)] {
                let password = Data((0..<passwordLength).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ iterations) })
                let salt = Data((0..<saltLength).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ passwordLength) })

                let key = try PBKDF2.deriveSHA256Key(
                    password: password,
                    salt: salt,
                    iterations: iterations,
                    outputByteCount: outputByteCount
                )

                XCTAssertEqual(
                    key.withUnsafeBytes { Data($0) },
                    previousImplementation(
                        password: password,
                        salt: salt,
                        iterations: iterations,
                        outputByteCount: outputByteCount
                    ),
                    "iterations \(iterations), output \(outputByteCount), password \(passwordLength) bytes, "
                        + "salt \(saltLength) bytes"
                )
            }
        }
    }

    func testMatchesThePreviousImplementationAtTheProductionCost() throws {
        let password = Data("731905".utf8)
        let salt = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        let iterations = AuthenticationService.Policy.production.derivationIterations

        let key = try PBKDF2.deriveSHA256Key(password: password, salt: salt, iterations: iterations)

        XCTAssertEqual(
            key.withUnsafeBytes { Data($0) },
            previousImplementation(password: password, salt: salt, iterations: iterations, outputByteCount: 32)
        )
    }

    func testRejectsInvalidParameters() {
        let password = Data("482916".utf8)
        let salt = Data(repeating: 1, count: 16)

        XCTAssertThrowsError(try PBKDF2.deriveSHA256Key(password: password, salt: salt, iterations: 0))
        XCTAssertThrowsError(try PBKDF2.deriveSHA256Key(password: password, salt: salt, iterations: -1))
        XCTAssertThrowsError(try PBKDF2.deriveSHA256Key(password: Data(), salt: salt, iterations: 1))
        XCTAssertThrowsError(try PBKDF2.deriveSHA256Key(password: password, salt: Data(), iterations: 1))
        XCTAssertThrowsError(
            try PBKDF2.deriveSHA256Key(password: password, salt: salt, iterations: 1, outputByteCount: 0)
        )
    }

    private func derivedHex(_ password: String, _ salt: String, iterations: Int, outputByteCount: Int) throws -> String {
        let key = try PBKDF2.deriveSHA256Key(
            password: Data(password.utf8),
            salt: Data(salt.utf8),
            iterations: iterations,
            outputByteCount: outputByteCount
        )
        return key.withUnsafeBytes { Data($0) }.hexadecimalString
    }

    private func previousImplementation(password: Data, salt: Data, iterations: Int, outputByteCount: Int) -> Data {
        let passwordKey = SymmetricKey(data: password)
        let hashLength = SHA256.Digest.byteCount
        let blockCount = (outputByteCount + hashLength - 1) / hashLength
        var derived = Data()
        for blockIndex in 1...blockCount {
            var blockInput = salt
            blockInput.appendBigEndian(UInt32(blockIndex))
            var previous = Data(HMAC<SHA256>.authenticationCode(for: blockInput, using: passwordKey))
            var accumulator = previous
            if iterations > 1 {
                for _ in 2...iterations {
                    previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: passwordKey))
                    for index in accumulator.indices {
                        accumulator[index] ^= previous[index]
                    }
                }
            }
            derived.append(accumulator)
        }
        return Data(derived.prefix(outputByteCount))
    }
}
