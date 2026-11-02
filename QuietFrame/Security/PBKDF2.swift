import CommonCrypto
import CryptoKit
import Foundation

enum PBKDF2 {
    /// Standard PBKDF2-HMAC-SHA256 output, so keys derived by earlier app versions are reproduced exactly.
    static func deriveSHA256Key(
        password: Data,
        salt: Data,
        iterations: Int,
        outputByteCount: Int = 32
    ) throws -> SymmetricKey {
        guard iterations > 0,
              outputByteCount > 0,
              !password.isEmpty,
              !salt.isEmpty,
              let rounds = UInt32(exactly: iterations) else {
            throw VaultError.invalidInput("The key derivation parameters are invalid.")
        }

        var derived = Data(count: outputByteCount)
        defer { derived.resetBytes(in: 0..<derived.count) }
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: CChar.self).baseAddress,
                        passwordBytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedBytes.count
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw VaultError.invalidInput("The key derivation parameters are invalid.")
        }
        return SymmetricKey(data: derived)
    }
}
