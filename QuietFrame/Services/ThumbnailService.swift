import Foundation
import ImageIO
import Observation
import UIKit

/// Decodes off the main thread; decoded images live only in a memory cache, which is emptied when the vault locks.
@MainActor
@Observable
final class ThumbnailService {
    nonisolated static let storedPixelSize = 720
    private nonisolated static let pixelSizeStep = 64
    private nonisolated static let maximumEncryptedByteCount = 16 * 1_048_576

    private struct CacheKey: Hashable {
        let identifier: String
        let pixelSize: Int

        var cacheName: NSString {
            "\(identifier)@\(pixelSize)" as NSString
        }
    }

    @MainActor
    private final class Load {
        let id: UInt64
        let task: Task<UIImage?, Never>
        var waiterCount = 0
        var cancelledWaiterCount = 0
        var isPrefetch = false

        init(id: UInt64, task: Task<UIImage?, Never>) {
            self.id = id
            self.task = task
        }
    }

    /// Changes whenever the cache is emptied, so views showing a thumbnail load it again.
    private(set) var generation: UInt64 = 0

    private let storage: any SecureFileStoring
    private let cache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var loads: [CacheKey: Load] = [:]
    @ObservationIgnored private var cachedPixelSizes: [String: Set<Int>] = [:]
    @ObservationIgnored private var sizeIndexPruneThreshold = 2_048
    @ObservationIgnored private var nextLoadID: UInt64 = 0

    init(storage: any SecureFileStoring, cacheByteLimit: Int = ThumbnailService.defaultCacheByteLimit) {
        self.storage = storage
        cache.totalCostLimit = cacheByteLimit
    }

    nonisolated static var defaultCacheByteLimit: Int {
        ProcessInfo.processInfo.physicalMemory >= 4 * 1_073_741_824 ? 96 * 1_048_576 : 48 * 1_048_576
    }

    nonisolated static func pixelSize(forPoints points: CGFloat, scale: CGFloat) -> Int {
        guard points.isFinite, scale.isFinite, points > 0, scale > 0 else { return storedPixelSize }
        return steppedPixelSize(Int((points * scale).rounded(.up)))
    }

    /// The short side has to cover the square, so the long side grows with the aspect ratio.
    nonisolated static func pixelSize(fillingSquareOf side: CGFloat, scale: CGFloat, mediaPixelSize: CGSize) -> Int {
        let long = max(mediaPixelSize.width, mediaPixelSize.height)
        let short = min(mediaPixelSize.width, mediaPixelSize.height)
        let aspectRatio = short > 0 && long.isFinite ? long / short : 1
        return pixelSize(forPoints: side * aspectRatio, scale: scale)
    }

    nonisolated static func steppedPixelSize(_ pixelSize: Int) -> Int {
        let positive = max(pixelSize, 1)
        let stepped = (positive + pixelSizeStep - 1) / pixelSizeStep * pixelSizeStep
        return min(stepped, storedPixelSize)
    }

    func image(for media: VaultMedia, pixelSize: Int = ThumbnailService.storedPixelSize) async -> UIImage? {
        guard let identifier = media.thumbnailIdentifier else { return nil }
        let key = CacheKey(identifier: identifier, pixelSize: Self.steppedPixelSize(pixelSize))
        if let cached = cachedImage(identifier: identifier, atLeast: key.pixelSize) { return cached }

        let load = loads[key] ?? startLoad(for: key, priority: Task.currentPriority)
        load.waiterCount += 1
        load.isPrefetch = false
        return await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiterCancelled(on: load, key: key)
            }
        }
    }

    func cachedImage(for media: VaultMedia, pixelSize: Int) -> UIImage? {
        guard let identifier = media.thumbnailIdentifier else { return nil }
        return cachedImage(identifier: identifier, atLeast: Self.steppedPixelSize(pixelSize))
    }

    func cachedImage(for media: VaultMedia) -> UIImage? {
        guard let identifier = media.thumbnailIdentifier, let sizes = cachedPixelSizes[identifier] else { return nil }
        for size in sizes.sorted(by: >) {
            if let image = cache.object(forKey: CacheKey(identifier: identifier, pixelSize: size).cacheName) {
                return image
            }
        }
        return nil
    }

    func prefetch(_ media: [VaultMedia], pixelSize: (VaultMedia) -> Int) {
        var wanted = Set<CacheKey>()
        for item in media {
            guard let identifier = item.thumbnailIdentifier else { continue }
            let size = Self.steppedPixelSize(pixelSize(item))
            let key = CacheKey(identifier: identifier, pixelSize: size)
            wanted.insert(key)
            guard loads[key] == nil, cachedImage(identifier: identifier, atLeast: size) == nil else { continue }
            startLoad(for: key, priority: .utility).isPrefetch = true
        }
        for (key, load) in loads where load.isPrefetch && load.waiterCount == 0 && !wanted.contains(key) {
            load.task.cancel()
            loads[key] = nil
        }
    }

    func removeImages(forThumbnailIdentifiers identifiers: some Sequence<String>) {
        let removed = Set(identifiers)
        guard !removed.isEmpty else { return }
        for identifier in removed {
            for size in cachedPixelSizes.removeValue(forKey: identifier) ?? [] {
                cache.removeObject(forKey: CacheKey(identifier: identifier, pixelSize: size).cacheName)
            }
        }
        for (key, load) in loads where removed.contains(key.identifier) {
            load.task.cancel()
            loads[key] = nil
        }
    }

    func clearCache() {
        generation &+= 1
        loads.values.forEach { $0.task.cancel() }
        loads.removeAll()
        cachedPixelSizes.removeAll()
        sizeIndexPruneThreshold = 2_048
        cache.removeAllObjects()
    }

    private func cachedImage(identifier: String, atLeast pixelSize: Int) -> UIImage? {
        guard let sizes = cachedPixelSizes[identifier] else { return nil }
        var match: UIImage?
        var evictedSizes: [Int] = []
        for size in sizes.sorted() {
            if let image = cache.object(forKey: CacheKey(identifier: identifier, pixelSize: size).cacheName) {
                if match == nil, size >= pixelSize {
                    match = image
                }
            } else {
                evictedSizes.append(size)
            }
        }
        if !evictedSizes.isEmpty {
            let liveSizes = sizes.subtracting(evictedSizes)
            cachedPixelSizes[identifier] = liveSizes.isEmpty ? nil : liveSizes
        }
        return match
    }

    @discardableResult
    private func startLoad(for key: CacheKey, priority: TaskPriority) -> Load {
        nextLoadID &+= 1
        let loadID = nextLoadID
        let storage = storage
        let task = Task<UIImage?, Never>(priority: priority) { [weak self] in
            let image = await Self.decodedThumbnail(
                identifier: key.identifier,
                pixelSize: key.pixelSize,
                storage: storage
            )
            self?.finishLoad(id: loadID, key: key, image: image)
            return image
        }
        let load = Load(id: loadID, task: task)
        loads[key] = load
        return load
    }

    /// Only a load that is still registered may fill the cache: clearing, eviction and cancellation unregister it.
    private func finishLoad(id: UInt64, key: CacheKey, image: UIImage?) {
        guard loads[key]?.id == id else { return }
        loads[key] = nil
        guard let image else { return }
        cache.setObject(image, forKey: key.cacheName, cost: Self.byteCost(of: image))
        cachedPixelSizes[key.identifier, default: []].insert(key.pixelSize)
        pruneSizeIndexIfNeeded()
    }

    private func waiterCancelled(on load: Load, key: CacheKey) {
        load.cancelledWaiterCount += 1
        guard load.cancelledWaiterCount >= load.waiterCount, loads[key]?.id == load.id else { return }
        load.task.cancel()
        loads[key] = nil
    }

    private func pruneSizeIndexIfNeeded() {
        guard cachedPixelSizes.count > sizeIndexPruneThreshold else { return }
        for (identifier, sizes) in cachedPixelSizes {
            let liveSizes = sizes.filter {
                cache.object(forKey: CacheKey(identifier: identifier, pixelSize: $0).cacheName) != nil
            }
            cachedPixelSizes[identifier] = liveSizes.isEmpty ? nil : liveSizes
        }
        sizeIndexPruneThreshold = max(2_048, cachedPixelSizes.count * 2)
    }

    private nonisolated static func decodedThumbnail(
        identifier: String,
        pixelSize: Int,
        storage: any SecureFileStoring
    ) async -> UIImage? {
        do {
            try Task.checkCancellation()
            let data = try await storage.decryptData(
                identifier: identifier,
                location: .thumbnails,
                maximumByteCount: maximumEncryptedByteCount
            )
            try Task.checkCancellation()
            return downsampledImage(from: data, maximumPixelSize: pixelSize)
        } catch {
            return nil
        }
    }

    /// Decodes straight to a bitmap, so nothing is left to decode when the image is first drawn.
    nonisolated static func downsampledImage(from data: Data, maximumPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    private nonisolated static func byteCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}
