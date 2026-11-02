import AVFoundation
import Foundation

/// A video played straight from its encrypted file. AVFoundation asks for byte ranges through a private URL scheme
/// and gets only those ranges, decrypted in memory, so no plaintext copy is written.
@MainActor
final class EncryptedVideoStream {
    let asset: AVURLAsset
    private let loader: EncryptedVideoResourceLoader

    init(
        reader: EncryptedFileReader,
        contentTypeIdentifier: String,
        responseByteCount: Int = EncryptedVideoResourceLoader.defaultResponseByteCount
    ) throws {
        // A random name: the URL never carries the item's identifier or its original filename.
        guard let url = URL(string: "\(EncryptedVideoResourceLoader.scheme)://video/\(UUID().uuidString)") else {
            throw VaultError.fileOperationFailed
        }
        let loader = EncryptedVideoResourceLoader(
            reader: reader,
            contentTypeIdentifier: contentTypeIdentifier,
            responseByteCount: responseByteCount
        )
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        self.loader = loader
        self.asset = asset
    }

    /// Stops pending reads and closes the file. The asset cannot load anything afterwards.
    func invalidate() {
        asset.cancelLoading()
        loader.invalidate()
    }
}

final class EncryptedVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "quietframe-encrypted"
    /// AVFoundation gets data in pieces no larger than one container chunk.
    static let defaultResponseByteCount = 1_048_576

    let queue = DispatchQueue(label: "com.quietframe.vault.encrypted-video")
    private let reader: EncryptedFileReader
    private let contentTypeIdentifier: String
    private let responseByteCount: Int64
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isInvalidated = false

    init(
        reader: EncryptedFileReader,
        contentTypeIdentifier: String,
        responseByteCount: Int = EncryptedVideoResourceLoader.defaultResponseByteCount
    ) {
        self.reader = reader
        self.contentTypeIdentifier = contentTypeIdentifier
        self.responseByteCount = Int64(max(1, responseByteCount))
    }

    func invalidate() {
        queue.async { [self] in
            isInvalidated = true
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            let reader = reader
            Task { await reader.close() }
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isInvalidated, loadingRequest.request.url?.scheme == Self.scheme else { return false }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentTypeIdentifier
            information.contentLength = reader.plaintextByteCount
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let start = dataRequest.currentOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? reader.plaintextByteCount
            : min(dataRequest.requestedOffset + Int64(dataRequest.requestedLength), reader.plaintextByteCount)
        let key = ObjectIdentifier(loadingRequest)
        let reader = reader
        let queue = queue
        let pieceByteCount = responseByteCount
        tasks[key] = Task { [weak self] in
            var offset = start
            do {
                while offset < end {
                    try Task.checkCancellation()
                    let length = Int(min(pieceByteCount, end - offset))
                    let data = try await reader.read(offset: offset, length: length)
                    guard !data.isEmpty else { break }
                    queue.async {
                        guard !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
                        dataRequest.respond(with: data)
                    }
                    offset += Int64(data.count)
                }
                queue.async {
                    self?.tasks[key] = nil
                    guard !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
                    loadingRequest.finishLoading()
                }
            } catch {
                queue.async {
                    self?.tasks[key] = nil
                    guard !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }
}
