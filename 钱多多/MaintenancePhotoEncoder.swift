import UIKit

/// The existing screenshot policy, executed only inside the private maintenance context.
nonisolated enum MaintenancePhotoEncoder {
    static func normalizedData(_ data: Data, targetByteCount: Int) -> Data? {
        guard let image = UIImage(data: data) else { return data }
        let maxSide: CGFloat = 560
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maxSide ? maxSide / longestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let renderedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        for quality in stride(from: 0.62, through: 0.36, by: -0.08) {
            guard let compressed = renderedImage.jpegData(compressionQuality: quality) else { continue }
            if compressed.count <= targetByteCount { return compressed }
        }
        return renderedImage.jpegData(compressionQuality: 0.32)
    }
}
