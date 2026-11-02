import Foundation

extension FileHandle {
    /// Exactly `count` bytes from the current offset, indexed from zero; a file that ends first is corrupted.
    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 else { throw VaultError.corruptedFile }
        guard count > 0 else { return Data() }
        let first = try read(upToCount: count) ?? Data()
        guard !first.isEmpty else { throw VaultError.corruptedFile }
        if first.count == count, first.startIndex == 0 { return first }

        var result = Data()
        result.reserveCapacity(count)
        result.append(first)
        while result.count < count {
            let next = try read(upToCount: count - result.count) ?? Data()
            guard !next.isEmpty else { throw VaultError.corruptedFile }
            result.append(next)
        }
        return result
    }
}
