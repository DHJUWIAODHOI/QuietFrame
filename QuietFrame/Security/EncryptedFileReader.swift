import CryptoKit
import Foundation

/// Random-access reads of one encrypted file, so media can play without a plaintext copy on disk. Every chunk is
/// authenticated as it is read, and reads stop working as soon as the vault locks.
actor EncryptedFileReader {
    nonisolated let plaintextByteCount: Int64

    private let handle: FileHandle
    private let session: VaultSession
    private let generation: UInt64
    private let fileKey: SymmetricKey
    private let encodedHeader: Data
    private let noncePrefix: Data
    private let chunkByteCount: Int
    private var lastChunk: (index: UInt32, plaintext: Data)?
    private var isClosed = false

    init(
        handle: FileHandle,
        session: VaultSession,
        generation: UInt64,
        fileKey: SymmetricKey,
        encodedHeader: Data,
        noncePrefix: Data,
        chunkByteCount: Int,
        plaintextByteCount: Int64
    ) {
        self.handle = handle
        self.session = session
        self.generation = generation
        self.fileKey = fileKey
        self.encodedHeader = encodedHeader
        self.noncePrefix = noncePrefix
        self.chunkByteCount = chunkByteCount
        self.plaintextByteCount = plaintextByteCount
    }

    deinit {
        try? handle.close()
    }

    /// Up to `length` plaintext bytes starting at `offset`; fewer only at the end of the file.
    func read(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0 else { throw VaultError.invalidInput("The read range is invalid.") }
        let end = min(offset + Int64(length), plaintextByteCount)
        guard offset < end else { return Data() }
        var result = Data()
        result.reserveCapacity(Int(end - offset))
        var position = offset
        while position < end {
            let index = UInt32(position / Int64(chunkByteCount))
            let chunkStart = Int64(index) * Int64(chunkByteCount)
            let plaintext = try await chunk(index)
            let lower = Int(position - chunkStart)
            let upper = min(plaintext.count, Int(end - chunkStart))
            guard lower < upper else { throw VaultError.corruptedFile }
            result.append(plaintext[plaintext.startIndex + lower ..< plaintext.startIndex + upper])
            position = chunkStart + Int64(upper)
        }
        return result
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        lastChunk = nil
        try? handle.close()
    }

    private func chunk(_ index: UInt32) async throws -> Data {
        guard !isClosed else { throw VaultError.fileOperationFailed }
        try Task.checkCancellation()
        do {
            try await session.validate(generation)
        } catch {
            lastChunk = nil
            throw error
        }
        guard !isClosed else { throw VaultError.fileOperationFailed }
        if let lastChunk, lastChunk.index == index { return lastChunk.plaintext }
        let chunkStart = Int64(index) * Int64(chunkByteCount)
        let plaintextCount = Int(min(Int64(chunkByteCount), plaintextByteCount - chunkStart))
        let fileOffset = UInt64(encodedHeader.count) + UInt64(index) * UInt64(chunkByteCount + 16)
        do {
            try handle.seek(toOffset: fileOffset)
            let sealedChunk = try handle.readExactly(plaintextCount + 16)
            let box = try AES.GCM.SealedBox(
                nonce: ChunkedEncryptionService.makeNonce(prefix: noncePrefix, chunkIndex: index),
                ciphertext: sealedChunk.prefix(plaintextCount),
                tag: sealedChunk.suffix(16)
            )
            let plaintext = try AES.GCM.open(
                box,
                using: fileKey,
                authenticating: ChunkedEncryptionService.additionalData(header: encodedHeader, chunkIndex: index)
            )
            lastChunk = (index, plaintext)
            return plaintext
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.corruptedFile
        }
    }
}
