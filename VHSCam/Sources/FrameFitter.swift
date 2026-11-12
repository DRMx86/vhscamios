import CoreImage
import CoreVideo
import UIKit

/// Scales and center-crops images into BGRA pixel buffers (used by the editor for photos and video frames).
final class FrameFitter {
    private let ci = CIContext()
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0

    /// Output size for a source size: short side == shortSide (even), or a shortSide x shortSide square.
    static func targetSize(width: Int, height: Int, shortSide: Int, square: Bool) -> (Int, Int) {
        let s = shortSide & ~1
        if square { return (s, s) }
        let scale = Double(s) / Double(max(1, min(width, height)))
        return (max(2, Int((Double(width) * scale).rounded()) & ~1),
                max(2, Int((Double(height) * scale).rounded()) & ~1))
    }

    func fit(_ image: CIImage, shortSide: Int, square: Bool) -> CVPixelBuffer? {
        let ext = image.extent
        guard ext.width > 1, ext.height > 1 else { return nil }
        let (w, h) = Self.targetSize(width: Int(ext.width), height: Int(ext.height),
                                     shortSide: shortSide, square: square)
        let scale = CGFloat(shortSide & ~1) / min(ext.width, ext.height)

        var scaled = image.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        if let f = CIFilter(name: "CILanczosScaleTransform") {
            f.setValue(scaled, forKey: kCIInputImageKey)
            f.setValue(scale, forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let out = f.outputImage { scaled = out } else { scaled = scaled.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        } else {
            scaled = scaled.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let x = scaled.extent.minX + (scaled.extent.width - CGFloat(w)) / 2
        let y = scaled.extent.minY + (scaled.extent.height - CGFloat(h)) / 2
        let cropped = scaled
            .cropped(to: CGRect(x: x, y: y, width: CGFloat(w), height: CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))

        guard let dst = makeBuffer(w, h) else { return nil }
        ci.render(cropped, to: dst, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return dst
    }

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    func cgImage(from pb: CVPixelBuffer) -> CGImage? {
        let img = CIImage(cvPixelBuffer: pb)
        return ci.createCGImage(img, from: img.extent)
    }

    func uiImage(from pb: CVPixelBuffer) -> UIImage? {
        cgImage(from: pb).map { UIImage(cgImage: $0) }
    }

    func jpegData(from pb: CVPixelBuffer, quality: CGFloat = 0.95) -> Data? {
        uiImage(from: pb)?.jpegData(compressionQuality: quality)
    }

    /// Upright, downscaled copy of a picked photo as a CIImage.
    static func prepare(_ image: UIImage, maxSide: CGFloat = 2560) -> CIImage? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let upright = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cg = upright.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}
