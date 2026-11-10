import UIKit

enum ImageEncoder {
    static func jpeg(from data: Data, maxSide: CGFloat = 1024, quality: CGFloat = 0.6) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, maxSide: maxSide, quality: quality)
    }

    static func jpeg(from image: UIImage, maxSide: CGFloat = 1024, quality: CGFloat = 0.6) -> Data? {
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

    /// JPEG small enough for the vision APIs. Shrinks further if the first pass is still heavy.
    static func payload(from image: UIImage, maxSide: CGFloat = 1024, maxBytes: Int = 700_000) -> Data? {
        let qualities: [CGFloat] = [0.6, 0.45, 0.35]
        let sides: [CGFloat] = [maxSide, 800]
        for side in sides {
            for quality in qualities {
                guard let data = jpeg(from: image, maxSide: side, quality: quality) else { continue }
                if data.count <= maxBytes { return data }
            }
        }
        return jpeg(from: image, maxSide: 640, quality: 0.35)
    }

    static func displayImage(from image: UIImage, maxSide: CGFloat = 900) -> UIImage {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return image }
        let longest = max(size.width, size.height)
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
