import CryptoKit
import Foundation

enum PBKDF2 {
    static func deriveSHA256Key(
        password: Data,
        salt: Data,
        iterations: Int,
        outputByteCount: Int = 32
    ) throws -> SymmetricKey {
        guard iterations > 0, outputByteCount > 0 else {
            throw VaultError.invalidInput("The key derivation parameters are invalid.")
        }

        let passwordKey = SymmetricKey(data: password)
        let hashLength = SHA256.Digest.byteCount
        let blockCount = Int(ceil(Double(outputByteCount) / Double(hashLength)))
        var derived = Data()
        derived.reserveCapacity(blockCount * hashLength)

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

        return SymmetricKey(data: derived.prefix(outputByteCount))
    }
}
