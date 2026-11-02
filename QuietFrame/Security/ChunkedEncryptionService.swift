import CryptoKit
import Foundation

struct EncryptionResult: Sendable, Equatable {
    let plaintextByteCount: Int64
    let fingerprint: String
}

typealias FileProgressHandler = @Sendable (Double) async -> Void

protocol FileEncrypting: Sendable {
    func encryptFile(
        at inputURL: URL,
        to outputURL: URL,
        progress: FileProgressHandler?
    ) async throws -> EncryptionResult

    func encryptData(_ plaintext: Data, to outputURL: URL) async throws -> EncryptionResult

    func decryptFile(
        at inputURL: URL,
        to outputURL: URL,
        progress: FileProgressHandler?
    ) async throws

    func decryptData(at inputURL: URL, maximumByteCount: Int) async throws -> Data
    func openReader(at inputURL: URL) async throws -> EncryptedFileReader
}

extension FileEncrypting {
    func openReader(at inputURL: URL) async throws -> EncryptedFileReader {
        throw VaultError.fileOperationFailed
    }
}

actor ChunkedEncryptionService: FileEncrypting {
    private struct Header {
        static let magic = Data([0x51, 0x46, 0x52, 0x41, 0x4d, 0x45, 0x30, 0x31]) // QFRAME01
        static let encodedByteCount = 48

        let chunkByteCount: UInt32
        let plaintextByteCount: UInt64
        let salt: Data
        let noncePrefix: Data

        func encode() -> Data {
            var data = Data()
            data.reserveCapacity(Self.encodedByteCount)
            data.append(Self.magic)
            data.append(1) // Format version.
            data.append(0) // Flags.
            data.appendBigEndian(UInt16(0))
            data.appendBigEndian(chunkByteCount)
            data.appendBigEndian(plaintextByteCount)
            data.append(salt)
            data.append(noncePrefix)
            return data
        }

        static func decode(_ data: Data) throws -> Header {
            guard data.count == encodedByteCount,
                  Data(data.prefix(magic.count)) == magic,
                  data[8] == 1,
                  data[9] == 0,
                  data.uint16(at: 10) == 0,
                  let chunkByteCount = data.uint32(at: 12),
                  let plaintextByteCount = data.uint64(at: 16),
                  chunkByteCount >= 64 * 1_024,
                  chunkByteCount <= 16 * 1_024 * 1_024,
                  plaintextByteCount > 0 else {
                throw VaultError.corruptedFile
            }
            return Header(
                chunkByteCount: chunkByteCount,
                plaintextByteCount: plaintextByteCount,
                salt: Data(data[24..<40]),
                noncePrefix: Data(data[40..<48])
            )
        }
    }

    private let session: VaultSession
    private let fileManager: FileManager
    private let chunkByteCount: Int

    init(
        session: VaultSession,
        fileManager: FileManager = .default,
        chunkByteCount: Int = 1_048_576
    ) {
        self.session = session
        self.fileManager = fileManager
        self.chunkByteCount = chunkByteCount
    }

    func encryptFile(
        at inputURL: URL,
        to outputURL: URL,
        progress: FileProgressHandler? = nil
    ) async throws -> EncryptionResult {
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL, hasSupportedChunkByteCount else {
            throw VaultError.invalidInput("The encryption file parameters are invalid.")
        }

        let keyAccess = try await session.keyAccess()
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { input.closeFile() }
        let plaintextByteCount = try input.seekToEnd()
        try input.seek(toOffset: 0)
        return try await encrypt(
            plaintextByteCount: plaintextByteCount,
            keyAccess: keyAccess,
            to: outputURL,
            progress: progress
        ) { byteCount in
            try input.readExactly(byteCount)
        }
    }

    /// Writes the same container as `encryptFile` from bytes held in memory, so they never reach disk unencrypted.
    func encryptData(_ plaintext: Data, to outputURL: URL) async throws -> EncryptionResult {
        guard hasSupportedChunkByteCount else {
            throw VaultError.invalidInput("The encryption file parameters are invalid.")
        }

        let keyAccess = try await session.keyAccess()
        var offset = plaintext.startIndex
        return try await encrypt(
            plaintextByteCount: UInt64(plaintext.count),
            keyAccess: keyAccess,
            to: outputURL,
            progress: nil
        ) { byteCount in
            let end = offset + byteCount
            defer { offset = end }
            return plaintext.subdata(in: offset..<end)
        }
    }

    private var hasSupportedChunkByteCount: Bool {
        chunkByteCount >= 64 * 1_024 && chunkByteCount <= 16 * 1_024 * 1_024
    }

    private func encrypt(
        plaintextByteCount: UInt64,
        keyAccess: VaultSession.KeyAccess,
        to outputURL: URL,
        progress: FileProgressHandler?,
        readChunk: (Int) throws -> Data
    ) async throws -> EncryptionResult {
        guard plaintextByteCount > 0 else { throw VaultError.unsupportedFileType }

        let salt = try Data.secureRandom(count: 16)
        let noncePrefix = try Data.secureRandom(count: 8)
        let header = Header(
            chunkByteCount: UInt32(chunkByteCount),
            plaintextByteCount: plaintextByteCount,
            salt: salt,
            noncePrefix: noncePrefix
        )
        let encodedHeader = header.encode()
        let fileKey = Self.deriveFileKey(masterKey: keyAccess.key, salt: salt)

        guard fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw VaultError.fileOperationFailed
        }
        let output = try FileHandle(forWritingTo: outputURL)
        var completed = false
        defer {
            output.closeFile()
            if !completed { try? fileManager.removeItem(at: outputURL) }
        }

        do {
            try output.write(contentsOf: encodedHeader)
            var hasher = SHA256()
            var processed: UInt64 = 0
            var chunkIndex: UInt32 = 0

            while processed < plaintextByteCount {
                try Task.checkCancellation()
                try await session.validate(keyAccess.generation)
                let remaining = plaintextByteCount - processed
                let readCount = Int(min(UInt64(chunkByteCount), remaining))
                let plaintext = try readChunk(readCount)
                hasher.update(data: plaintext)

                let nonce = try Self.makeNonce(prefix: noncePrefix, chunkIndex: chunkIndex)
                let sealed = try AES.GCM.seal(
                    plaintext,
                    using: fileKey,
                    nonce: nonce,
                    authenticating: Self.additionalData(header: encodedHeader, chunkIndex: chunkIndex)
                )
                try output.write(contentsOf: sealed.ciphertext)
                try output.write(contentsOf: sealed.tag)

                processed += UInt64(plaintext.count)
                if let progress {
                    await progress(Double(processed) / Double(plaintextByteCount))
                }
                guard chunkIndex < UInt32.max else { throw VaultError.fileOperationFailed }
                chunkIndex += 1
            }

            try await session.validate(keyAccess.generation)
            try output.synchronize()
            let plaintextDigest = Data(hasher.finalize())
            let deduplicationKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: keyAccess.key,
                salt: Data(),
                info: Data("QuietFrame.deduplication-key.v1".utf8),
                outputByteCount: 32
            )
            let fingerprint = Data(HMAC<SHA256>.authenticationCode(
                for: plaintextDigest,
                using: deduplicationKey
            )).hexadecimalString
            completed = true
            return EncryptionResult(
                plaintextByteCount: Int64(clamping: plaintextByteCount),
                fingerprint: fingerprint
            )
        } catch is CancellationError {
            throw VaultError.importCancelled
        } catch {
            throw error
        }
    }

    func decryptFile(
        at inputURL: URL,
        to outputURL: URL,
        progress: FileProgressHandler? = nil
    ) async throws {
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw VaultError.invalidInput("The decryption file parameters are invalid.")
        }
        let keyAccess = try await session.keyAccess()
        guard fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw VaultError.fileOperationFailed
        }
        let output = try FileHandle(forWritingTo: outputURL)
        var completed = false
        defer {
            output.closeFile()
            if !completed { try? fileManager.removeItem(at: outputURL) }
        }

        do {
            try await decrypt(
                inputURL: inputURL,
                keyAccess: keyAccess,
                progress: progress
            ) { plaintext in
                try output.write(contentsOf: plaintext)
            }
            try output.synchronize()
            completed = true
        } catch is CancellationError {
            throw VaultError.importCancelled
        } catch {
            throw error
        }
    }

    func decryptData(at inputURL: URL, maximumByteCount: Int = 268_435_456) async throws -> Data {
        let keyAccess = try await session.keyAccess()
        var result = Data()
        try await decrypt(inputURL: inputURL, keyAccess: keyAccess, progress: nil) { plaintext in
            guard result.count <= maximumByteCount - plaintext.count else {
                throw VaultError.insufficientStorage
            }
            result.append(plaintext)
        }
        return result
    }

    private func decrypt(
        inputURL: URL,
        keyAccess: VaultSession.KeyAccess,
        progress: FileProgressHandler?,
        consume: (Data) throws -> Void
    ) async throws {
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { input.closeFile() }

        do {
            let encodedHeader = try input.readExactly(Header.encodedByteCount)
            let header = try Header.decode(encodedHeader)
            let fileKey = Self.deriveFileKey(masterKey: keyAccess.key, salt: header.salt)
            var processed: UInt64 = 0
            var chunkIndex: UInt32 = 0

            while processed < header.plaintextByteCount {
                try Task.checkCancellation()
                try await session.validate(keyAccess.generation)
                let remaining = header.plaintextByteCount - processed
                let plaintextCount = Int(min(UInt64(header.chunkByteCount), remaining))
                let ciphertext = try input.readExactly(plaintextCount)
                let tag = try input.readExactly(16)
                let nonce = try Self.makeNonce(prefix: header.noncePrefix, chunkIndex: chunkIndex)
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                let plaintext = try AES.GCM.open(
                    box,
                    using: fileKey,
                    authenticating: Self.additionalData(header: encodedHeader, chunkIndex: chunkIndex)
                )
                try consume(plaintext)

                processed += UInt64(plaintext.count)
                if let progress {
                    await progress(Double(processed) / Double(header.plaintextByteCount))
                }
                guard chunkIndex < UInt32.max else { throw VaultError.corruptedFile }
                chunkIndex += 1
            }

            try await session.validate(keyAccess.generation)
            let trailingData = try input.read(upToCount: 1) ?? Data()
            guard trailingData.isEmpty else { throw VaultError.corruptedFile }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.corruptedFile
        }
    }

    /// Opens a container for random-access reads. Its size must match its header exactly, so a truncated or padded
    /// file is rejected before anything is read; each chunk is authenticated as it is read.
    func openReader(at inputURL: URL) async throws -> EncryptedFileReader {
        let keyAccess = try await session.keyAccess()
        let input = try FileHandle(forReadingFrom: inputURL)
        do {
            let encodedHeader = try input.readExactly(Header.encodedByteCount)
            let header = try Header.decode(encodedHeader)
            let chunkSize = UInt64(header.chunkByteCount)
            let chunkCount = header.plaintextByteCount / chunkSize + (header.plaintextByteCount % chunkSize == 0 ? 0 : 1)
            let (expectedBytes, overflow) = header.plaintextByteCount.addingReportingOverflow(
                UInt64(Header.encodedByteCount) + chunkCount * 16
            )
            guard !overflow,
                  chunkCount <= UInt64(UInt32.max),
                  try input.seekToEnd() == expectedBytes,
                  let plaintextByteCount = Int64(exactly: header.plaintextByteCount) else {
                throw VaultError.corruptedFile
            }
            return EncryptedFileReader(
                handle: input,
                session: session,
                generation: keyAccess.generation,
                fileKey: Self.deriveFileKey(masterKey: keyAccess.key, salt: header.salt),
                encodedHeader: encodedHeader,
                noncePrefix: header.noncePrefix,
                chunkByteCount: Int(header.chunkByteCount),
                plaintextByteCount: plaintextByteCount
            )
        } catch let error as VaultError {
            try? input.close()
            throw error
        } catch {
            try? input.close()
            throw VaultError.corruptedFile
        }
    }

    private nonisolated static func deriveFileKey(masterKey: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: Data("QuietFrame.file-key.v1".utf8),
            outputByteCount: 32
        )
    }

    nonisolated static func makeNonce(prefix: Data, chunkIndex: UInt32) throws -> AES.GCM.Nonce {
        guard prefix.count == 8 else { throw VaultError.corruptedFile }
        var nonceData = prefix
        nonceData.appendBigEndian(chunkIndex)
        return try AES.GCM.Nonce(data: nonceData)
    }

    nonisolated static func additionalData(header: Data, chunkIndex: UInt32) -> Data {
        var data = header
        data.appendBigEndian(chunkIndex)
        return data
    }
}
