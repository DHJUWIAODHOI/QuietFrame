import CryptoKit
import XCTest
@testable import QuietFrame

/// Known answers for the key material vaults depend on, computed independently with Python's hashlib and hmac.
/// Any difference means existing vaults could stop opening or deduplicating.
final class CryptoVectorTests: XCTestCase {
    private let masterKey = Data(repeating: 0x4D, count: 32)
    private let countingSalt = Data((0..<16).map { UInt8($0) })

    func testPasscodeKeyAndVerifierAtTheProductionCost() throws {
        let wrappingKey = try PBKDF2.deriveSHA256Key(
            password: Data("246810".utf8),
            salt: countingSalt,
            iterations: AuthenticationService.Policy.production.derivationIterations
        )
        let verifier = Data(HMAC<SHA256>.authenticationCode(
            for: Data("QuietFrame.passcode.verifier.v1".utf8),
            using: wrappingKey
        ))

        XCTAssertEqual(
            wrappingKey.withUnsafeBytes { Data($0) }.hexadecimalString,
            "e581fe63248a39519e40246e98ec3b4ed5d6f67b48978f0f47c033a97d57bd77"
        )
        XCTAssertEqual(verifier.hexadecimalString, "8c32ac2beefdc71b0f29faa3bee455ac444983541a6f49dee781f3199608e158")
    }

    func testFileKeyDerivation() {
        let fileKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: countingSalt,
            info: Data("QuietFrame.file-key.v1".utf8),
            outputByteCount: 32
        )

        XCTAssertEqual(
            fileKey.withUnsafeBytes { Data($0) }.hexadecimalString,
            "fdec520f793611377d354b442053b42a9603cc047fa680fa1795b2b3c4c0828f"
        )
    }

    func testDuplicateFingerprintOfStoredMedia() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession()
        try await session.unlock(with: masterKey)
        let encryption = ChunkedEncryptionService(session: session)
        let input = directory.appendingPathComponent("plaintext")
        try Data((0..<80_000).map { UInt8($0 % 223) }).write(to: input)

        let result = try await encryption.encryptFile(
            at: input,
            to: directory.appendingPathComponent("encrypted.qfe"),
            progress: nil
        )

        XCTAssertEqual(result.plaintextByteCount, 80_000)
        XCTAssertEqual(result.fingerprint, "1575423b4e930169e9eac50f066ebd6ff8b175e5105434e37654c91999ce3450")
    }

    /// Decodes a container written by the app with nothing but the published layout: a 48-byte header, then each
    /// chunk's ciphertext and tag, sealed with the HKDF file key, the prefix-and-index nonce and header-plus-index AAD.
    func testContainerMatchesTheDocumentedLayout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession()
        try await session.unlock(with: masterKey)
        let encryption = ChunkedEncryptionService(session: session, chunkByteCount: 65_536)
        let plaintext = Data((0..<180_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let input = directory.appendingPathComponent("plaintext")
        let output = directory.appendingPathComponent("encrypted.qfe")
        try plaintext.write(to: input)

        _ = try await encryption.encryptFile(at: input, to: output, progress: nil)
        let container = try Data(contentsOf: output)

        XCTAssertEqual(container.count, 48 + 180_000 + 16 * 3)
        let header = Data(container.prefix(48))
        XCTAssertEqual(Data(header.prefix(8)), Data("QFRAME01".utf8))
        XCTAssertEqual(Array(header[8..<12]), [1, 0, 0, 0])
        XCTAssertEqual(header.uint32(at: 12), 65_536)
        XCTAssertEqual(header.uint64(at: 16), 180_000)
        let fileKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: Data(header[24..<40]),
            info: Data("QuietFrame.file-key.v1".utf8),
            outputByteCount: 32
        )
        var decoded = Data()
        var offset = 48
        var index: UInt32 = 0
        while decoded.count < plaintext.count {
            let count = min(65_536, plaintext.count - decoded.count)
            var nonce = Data(header[40..<48])
            nonce.appendBigEndian(index)
            var additionalData = header
            additionalData.appendBigEndian(index)
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: container[offset..<(offset + count)],
                tag: container[(offset + count)..<(offset + count + 16)]
            )
            decoded.append(try AES.GCM.open(box, using: fileKey, authenticating: additionalData))
            offset += count + 16
            index += 1
        }

        XCTAssertEqual(decoded, plaintext)
        XCTAssertEqual(offset, container.count)
    }
}
