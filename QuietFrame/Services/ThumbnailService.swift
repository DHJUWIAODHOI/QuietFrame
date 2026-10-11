import Foundation
import UIKit

@MainActor
final class ThumbnailService {
    private let storage: any SecureFileStoring
    private let cache = NSCache<NSString, UIImage>()
    private var tasks: [String: Task<UIImage?, Never>] = [:]
    private var generation: UInt64 = 0

    init(storage: any SecureFileStoring) {
        self.storage = storage
        cache.countLimit = 500
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(for media: VaultMedia) async -> UIImage? {
        guard let identifier = media.thumbnailIdentifier else { return nil }
        if let cached = cache.object(forKey: identifier as NSString) { return cached }
        if let task = tasks[identifier] { return await task.value }
        let requestGeneration = generation

        let task = Task<UIImage?, Never> { [storage, weak self] in
            do {
                let data = try await storage.decryptData(
                    identifier: identifier,
                    location: .thumbnails,
                    maximumByteCount: 16 * 1_024 * 1_024
                )
                guard !Task.isCancelled else { return nil }
                let image = await Task.detached(priority: .utility) {
                    UIImage(data: data)
                }.value
                guard let image, !Task.isCancelled else { return nil }
                await MainActor.run {
                    guard self?.generation == requestGeneration else { return }
                    let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                    self?.cache.setObject(image, forKey: identifier as NSString, cost: cost)
                }
                return image
            } catch {
                return nil
            }
        }
        tasks[identifier] = task
        let image = await task.value
        tasks[identifier] = nil
        return image
    }

    func cachedImage(for media: VaultMedia) -> UIImage? {
        guard let identifier = media.thumbnailIdentifier else { return nil }
        return cache.object(forKey: identifier as NSString)
    }

    func clearCache() {
        generation &+= 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        cache.removeAllObjects()
    }
}
