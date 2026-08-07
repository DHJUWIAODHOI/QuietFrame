import Foundation
import Security

extension Data {
    static func secureRandom(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else { throw VaultError.keychainFailure }
        return data
    }

    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for index in indices {
            difference |= self[index] ^ other[index]
        }
        return difference == 0
    }

    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func uint64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for byte in self[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
