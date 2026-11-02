import CryptoKit
import Foundation

/// Random-access reads, so media can play without a plaintext copy on disk; reads fail once the vault locks.
actor EncryptedFileReader {
    private struct DecryptedChunk {
        let index: UInt32
        let plaintext: Data
    }

    /// Playback and the frame strip read the same video at different offsets, so a few recent chunks are kept.
    private static let keptChunkLimit = 4

    nonisolated let plaintextByteCount: Int64

    private let handle: FileHandle
    private let session: VaultSession
    private let generation: UInt64
    private let fileKey: SymmetricKey
    private let encodedHeader: Data
    private let noncePrefix: Data
    private let chunkByteCount: Int
    private var recentChunks: [DecryptedChunk] = []
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
        recentChunks.removeAll()
        try? handle.close()
    }

    private func chunk(_ index: UInt32) async throws -> Data {
        guard !isClosed else { throw VaultError.fileOperationFailed }
        try Task.checkCancellation()
        do {
            try await session.validate(generation)
        } catch {
            recentChunks.removeAll()
            throw error
        }
        guard !isClosed else { throw VaultError.fileOperationFailed }
        if let position = recentChunks.firstIndex(where: { $0.index == index }) {
            let kept = recentChunks.remove(at: position)
            recentChunks.append(kept)
            return kept.plaintext
        }
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
            if recentChunks.count == Self.keptChunkLimit {
                recentChunks.removeFirst()
            }
            recentChunks.append(DecryptedChunk(index: index, plaintext: plaintext))
            return plaintext
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.corruptedFile
        }
    }
}
