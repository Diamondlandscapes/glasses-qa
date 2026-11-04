import UIKit

enum ImageEncoder {
    static func jpeg(from data: Data, maxSide: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, maxSide: maxSide, quality: quality)
    }

    static func jpeg(from image: UIImage, maxSide: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        let longest = max(size.width, size.height)
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
