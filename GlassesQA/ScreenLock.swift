import CoreImage
import UIKit
import Vision

/// Crops each still photo to the computer screen and keeps that crop steady.
struct ScreenLockResult {
    var jpeg: Data
    var preview: UIImage?
    var locked: Bool
}

final class ScreenLock {
    private struct Quad {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomLeft: CGPoint
        var bottomRight: CGPoint

        var bounds: CGRect {
            let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
            let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? 0
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var locked: Quad?
    private var misses = 0

    func process(_ image: UIImage) -> ScreenLockResult {
        let full = ImageEncoder.jpeg(from: image, maxSide: 1280, quality: 0.72) ?? Data()
        let probe = ImageEncoder.displayImage(from: image, maxSide: 960)
        guard let cgImage = probe.cgImage else {
            return ScreenLockResult(jpeg: full, preview: nil, locked: false)
        }
        let orientation = CGImagePropertyOrientation.up

        if let current = locked {
            if stillThere(cgImage: cgImage, orientation: orientation, quad: current) {
                misses = 0
                if let cropped = render(image, quad: current) {
                    return cropped
                }
            } else {
                misses += 1
                if misses < 2, let cropped = render(image, quad: current) {
                    return cropped
                }
                locked = nil
                misses = 0
            }
        }

        if let found = detect(cgImage: cgImage, orientation: orientation),
           let cropped = render(image, quad: found) {
            locked = found
            misses = 0
            return cropped
        }
        return ScreenLockResult(jpeg: full, preview: nil, locked: false)
    }

    private func stillThere(cgImage: CGImage, orientation: CGImagePropertyOrientation, quad: Quad) -> Bool {
        let rectangles = rectangles(cgImage: cgImage, orientation: orientation)
        if rectangles.contains(where: { iou($0.bounds, quad.bounds) > 0.35 }) {
            return true
        }
        let text = textBoxes(cgImage: cgImage, orientation: orientation)
        let inside = text.filter { quad.bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        return inside.count >= 3
    }

    private func detect(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Quad? {
        let rectangles = rectangles(cgImage: cgImage, orientation: orientation)
        if let best = rectangles.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            return expanded(best, by: 0.04)
        }
        let boxes = textBoxes(cgImage: cgImage, orientation: orientation)
        guard boxes.count >= 4 else { return nil }
        var union = boxes[0]
        for box in boxes.dropFirst() {
            union = union.union(box)
        }
        let area = union.width * union.height
        guard area > 0.06, area < 0.92 else { return nil }
        let padded = union.insetBy(dx: -union.width * 0.06, dy: -union.height * 0.06)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0.05, clamped.height > 0.05 else { return nil }
        return Quad(
            topLeft: CGPoint(x: clamped.minX, y: clamped.maxY),
            topRight: CGPoint(x: clamped.maxX, y: clamped.maxY),
            bottomLeft: CGPoint(x: clamped.minX, y: clamped.minY),
            bottomRight: CGPoint(x: clamped.maxX, y: clamped.minY)
        )
    }

    private func rectangles(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> [Quad] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.4
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 30
        request.minimumSize = 0.12
        request.minimumConfidence = 0.4
        request.maximumObservations = 6
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        try? handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            let box = observation.boundingBox
            let area = box.width * box.height
            guard area > 0.08, area < 0.94 else { return nil }
            return Quad(
                topLeft: observation.topLeft,
                topRight: observation.topRight,
                bottomLeft: observation.bottomLeft,
                bottomRight: observation.bottomRight
            )
        }
    }

    private func textBoxes(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        try? handler.perform([request])
        return (request.results ?? []).map(\.boundingBox).filter { $0.width > 0.01 && $0.height > 0.005 }
    }

    private func render(_ image: UIImage, quad: Quad) -> ScreenLockResult? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let extent = ciImage.extent
        func denormalize(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: extent.origin.x + point.x * extent.width,
                y: extent.origin.y + point.y * extent.height
            )
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: denormalize(quad.topLeft)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: denormalize(quad.topRight)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: denormalize(quad.bottomLeft)), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: denormalize(quad.bottomRight)), forKey: "inputBottomRight")
        guard var output = filter.outputImage, output.extent.width > 20, output.extent.height > 20 else {
            return nil
        }
        let longest = max(output.extent.width, output.extent.height)
        let scale = min(2.4, max(1, 1700 / longest))
        if scale > 1.01 {
            output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        output = output.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 1.3,
            kCIInputIntensityKey: 0.65
        ])
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        let sharpened = UIImage(cgImage: cg)
        guard let jpeg = sharpened.jpegData(compressionQuality: 0.78) else { return nil }
        return ScreenLockResult(
            jpeg: jpeg,
            preview: ImageEncoder.displayImage(from: sharpened, maxSide: 360),
            locked: true
        )
    }

    private func expanded(_ quad: Quad, by amount: CGFloat) -> Quad {
        let bounds = quad.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func push(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(1, max(0, center.x + (point.x - center.x) * (1 + amount))),
                y: min(1, max(0, center.y + (point.y - center.y) * (1 + amount)))
            )
        }
        return Quad(
            topLeft: push(quad.topLeft),
            topRight: push(quad.topRight),
            bottomLeft: push(quad.bottomLeft),
            bottomRight: push(quad.bottomRight)
        )
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        if intersection.isNull || intersection.isEmpty { return 0 }
        let interArea = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }

}
