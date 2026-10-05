import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Immagine in scala di grigi (orientamento del sensore, cioè "sdraiata").
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [Float]

    /// Media a blocchi del piano di luminanza di un fotogramma video.
    init?(lumaOf pixelBuffer: CVPixelBuffer, width outWidth: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let src = base.assumingMemoryBound(to: UInt8.self)
        width = outWidth
        height = outWidth * h / w
        pixels = [Float](repeating: 0, count: width * height)
        for ty in 0..<height {
            let y0 = ty * h / height, y1 = (ty + 1) * h / height
            for tx in 0..<width {
                let x0 = tx * w / width, x1 = (tx + 1) * w / width
                var sum = 0
                for y in y0..<y1 {
                    let row = src + y * stride
                    for x in x0..<x1 { sum += Int(row[x]) }
                }
                pixels[ty * width + tx] = Float(sum) / Float(max(1, (y1 - y0) * (x1 - x0)))
            }
        }
    }

    /// Foto JPEG ridotta, senza applicare l'orientamento EXIF (resta come il sensore).
    init?(jpeg data: Data, width outWidth: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: outWidth,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = outWidth
        let h = outWidth * image.height / image.width
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        pixels = bytes.map(Float.init)
    }

    private init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func halved() -> GrayImage {
        let w = width / 2, h = height / 2
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = 2 * y * width + 2 * x
                out[y * w + x] = (pixels[i] + pixels[i + 1] + pixels[i + width] + pixels[i + width + 1]) / 4
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Media zero e deviazione 1: confronta foto e video anche se luminosità e contrasto differiscono.
    func normalized() -> GrayImage {
        let n = Float(pixels.count)
        let mean = pixels.reduce(0, +) / n
        let variance = pixels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let std = max(variance.squareRoot(), 0.0001)
        return GrayImage(width: width, height: height, pixels: pixels.map { ($0 - mean) / std })
    }
}

/// Cerca lo spostamento (dx, dy) per cui `b(x+dx, y+dy)` assomiglia di più ad `a(x, y)`.
/// Restituisce lo spostamento e la correlazione (1 = identiche).
private func bestShift(_ a: GrayImage, _ b: GrayImage, center: (Int, Int), radius: Int) -> (dx: Int, dy: Int, score: Float) {
    let margin = max(abs(center.0), abs(center.1)) + radius + 1
    var best = (dx: 0, dy: 0, score: -Float.infinity)
    for dy in (center.1 - radius)...(center.1 + radius) {
        for dx in (center.0 - radius)...(center.0 + radius) {
            var sum: Float = 0
            var count = 0
            for y in margin..<(a.height - margin) {
                let ra = y * a.width
                let rb = (y + dy) * b.width + dx
                for x in margin..<(a.width - margin) {
                    sum += a.pixels[ra + x] * b.pixels[rb + x]
                }
                count += a.width - 2 * margin
            }
            let score = sum / Float(max(1, count))
            if score > best.score { best = (dx, dy, score) }
        }
    }
    return best
}

/// Spostamento del video rispetto alla foto, in pixel dell'immagine `photo` (orientamento sensore).
func measureShift(photo: GrayImage, video: GrayImage) -> (dx: Int, dy: Int, score: Float)? {
    guard photo.width == video.width, photo.height == video.height else { return nil }
    let a = photo.normalized(), b = video.normalized()
    // Prima grossolana (1/4), poi fine attorno al risultato.
    let a4 = a.halved().halved().normalized(), b4 = b.halved().halved().normalized()
    let coarse = bestShift(a4, b4, center: (0, 0), radius: 14)
    return bestShift(a, b, center: (coarse.dx * 4, coarse.dy * 4), radius: 5)
}
