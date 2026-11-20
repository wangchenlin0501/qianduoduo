import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Passive image content, so the surrounding association button owns taps and dragging.
struct TodoLinkedPoolThumbnail: View {
    @ObservedObject var record: AdRecord
    var size: CGFloat = 44

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var request: ThumbnailRequest {
        ThumbnailRequest(data: record.photoData, pixelSize: min(256, max(1, Int((size * displayScale).rounded(.up)))))
    }

    var body: some View {
        let request = request
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.thumbnailCornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: request) {
            image = nil
            guard let data = request.data else { return }
            let thumbnail = await TodoPoolThumbnailLoader.shared.image(from: data, pixelSize: request.pixelSize)
            guard !Task.isCancelled else { return }
            image = thumbnail.map { UIImage(cgImage: $0) }
        }
    }
}

nonisolated private struct ThumbnailRequest: Equatable, Sendable {
    let data: Data?
    let pixelSize: Int
}

/// ImageIO downsamples before decoding. Neither large-photo decoding nor hashing runs on the UI actor.
private actor TodoPoolThumbnailLoader {
    static let shared = TodoPoolThumbnailLoader()
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private var cachedCost = 0

    func image(from data: Data, pixelSize: Int) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "\(pixelSize):\(digest)"
        if let cached = cache[key] { return cached }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize
              ] as CFDictionary) else { return nil }
        guard !Task.isCancelled else { return nil }
        let cost = image.bytesPerRow * image.height
        while !cacheOrder.isEmpty && (cache.count >= 64 || cachedCost + cost > 4 * 1_024 * 1_024) {
            let oldest = cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cachedCost -= removed.bytesPerRow * removed.height
            }
        }
        cache[key] = image
        cacheOrder.append(key)
        cachedCost += cost
        return image
    }
}
