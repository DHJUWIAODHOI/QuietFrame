import UIKit

struct ImportPreviewLayout: Equatable, Sendable {
    let tileWidth: CGFloat
    let scale: CGFloat
    let firstScreenCount: Int
}

/// Review previews decoded at the size their tiles fill, in a memory-only cache with a byte budget. Background decodes
/// run ahead of the tiles; a tile that gets ahead of them decodes its own preview, so an item with a preview never
/// shows a placeholder.
@MainActor
final class ImportPreviewImages {
    private final class Entry {
        let image: UIImage
        let pixelSize: Int

        init(image: UIImage, pixelSize: Int) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }

    private let cache = NSCache<NSUUID, Entry>()
    private var loadingSizes: [UUID: Int] = [:]
    private var undecodableIDs: Set<UUID> = []
    private var generation: UInt64 = 0
#if DEBUG
    private(set) var decodeCount = 0
#endif

    nonisolated static var defaultByteLimit: Int {
        ProcessInfo.processInfo.physicalMemory >= 4 * 1_073_741_824 ? 64 * 1_048_576 : 32 * 1_048_576
    }

    init(byteLimit: Int = ImportPreviewImages.defaultByteLimit) {
        cache.totalCostLimit = byteLimit
    }

    /// Enough pixels to fill a square tile `tileWidth` points wide; the stored size when the media's size is unknown.
    nonisolated static func pixelSize(tileWidth: CGFloat, scale: CGFloat, metadata: MediaMetadata) -> Int {
        guard metadata.pixelWidth > 0, metadata.pixelHeight > 0 else { return ThumbnailService.storedPixelSize }
        return ThumbnailService.pixelSize(
            fillingSquareOf: tileWidth,
            scale: scale,
            mediaPixelSize: CGSize(width: metadata.pixelWidth, height: metadata.pixelHeight)
        )
    }

    func cachedImage(for id: UUID, atLeast pixelSize: Int) -> UIImage? {
        guard let entry = cache.object(forKey: id as NSUUID), entry.pixelSize >= pixelSize else { return nil }
        return entry.image
    }

    /// The preview a tile draws now: a cached one that is large enough, or one decoded on the spot.
    func image(for candidate: ImportPreviewCandidate, pixelSize: Int) -> UIImage? {
        if let image = cachedImage(for: candidate.id, atLeast: pixelSize) { return image }
        guard let data = candidate.source.thumbnailJPEGData, !undecodableIDs.contains(candidate.id) else { return nil }
        countDecode()
        guard let image = ThumbnailService.downsampledImage(from: data, maximumPixelSize: pixelSize) else {
            undecodableIDs.insert(candidate.id)
            return nil
        }
        store(image, pixelSize: pixelSize, for: candidate.id)
        return image
    }

    /// Decodes these previews off the main thread and returns once they are cached.
    func load(_ candidates: [ImportPreviewCandidate], tileWidth: CGFloat, scale: CGFloat) async {
        let requests = beginDecoding(candidates, tileWidth: tileWidth, scale: scale)
        let generation = generation
        await finishDecoding(requests, generation: generation)
    }

    /// Starts decoding these previews off the main thread without waiting for them.
    func prefetch(_ candidates: [ImportPreviewCandidate], tileWidth: CGFloat, scale: CGFloat) {
        let requests = beginDecoding(candidates, tileWidth: tileWidth, scale: scale)
        guard !requests.isEmpty else { return }
        let generation = generation
        Task {
            await self.finishDecoding(requests, generation: generation)
        }
    }

    func remove(_ id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
        loadingSizes[id] = nil
        undecodableIDs.remove(id)
    }

    /// Drops every preview. Decodes already running are discarded when they finish.
    func removeAll() {
        generation &+= 1
        loadingSizes.removeAll()
        undecodableIDs.removeAll()
        cache.removeAllObjects()
    }

    private func beginDecoding(
        _ candidates: [ImportPreviewCandidate],
        tileWidth: CGFloat,
        scale: CGFloat
    ) -> [ImportPreviewDecodeRequest] {
        var requests: [ImportPreviewDecodeRequest] = []
        for candidate in candidates {
            guard let data = candidate.source.thumbnailJPEGData, !undecodableIDs.contains(candidate.id) else { continue }
            let size = Self.pixelSize(tileWidth: tileWidth, scale: scale, metadata: candidate.source.metadata)
            guard cachedImage(for: candidate.id, atLeast: size) == nil,
                  (loadingSizes[candidate.id] ?? 0) < size else { continue }
            loadingSizes[candidate.id] = size
            requests.append(ImportPreviewDecodeRequest(id: candidate.id, data: data, pixelSize: size))
        }
        return requests
    }

    /// Only a decode that is still registered may fill the cache: removing an item, or every item, unregisters it.
    private func finishDecoding(_ requests: [ImportPreviewDecodeRequest], generation: UInt64) async {
        guard !requests.isEmpty else { return }
        await withTaskGroup(of: (ImportPreviewDecodeRequest, UIImage?).self) { group in
            for request in requests {
                group.addTask {
                    let decoded = await ImportPreviewImages.decodedPreview(from: request.data, pixelSize: request.pixelSize)
                    return (request, decoded)
                }
            }
            for await (request, decoded) in group {
                guard generation == self.generation, self.loadingSizes[request.id] == request.pixelSize else { continue }
                self.loadingSizes[request.id] = nil
                self.countDecode()
                if let decoded {
                    if self.cachedImage(for: request.id, atLeast: request.pixelSize) == nil {
                        self.store(decoded, pixelSize: request.pixelSize, for: request.id)
                    }
                } else {
                    self.undecodableIDs.insert(request.id)
                }
            }
        }
    }

    private func store(_ image: UIImage, pixelSize: Int, for id: UUID) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(Entry(image: image, pixelSize: pixelSize), forKey: id as NSUUID, cost: cost)
    }

    private func countDecode() {
#if DEBUG
        decodeCount += 1
#endif
    }

    /// Async so the decode runs off the main actor.
    private nonisolated static func decodedPreview(from data: Data, pixelSize: Int) async -> UIImage? {
        ThumbnailService.downsampledImage(from: data, maximumPixelSize: pixelSize)
    }
}

private struct ImportPreviewDecodeRequest: Sendable {
    let id: UUID
    let data: Data
    let pixelSize: Int
}
