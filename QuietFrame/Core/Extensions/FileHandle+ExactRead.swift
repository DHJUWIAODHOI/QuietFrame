import Foundation

extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 else { throw VaultError.corruptedFile }
        var result = Data()
        result.reserveCapacity(count)

        while result.count < count {
            let next = try read(upToCount: count - result.count) ?? Data()
            guard !next.isEmpty else { throw VaultError.corruptedFile }
            result.append(next)
        }
        return result
    }
}
