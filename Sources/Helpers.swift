import AVFoundation
import UIKit
import ImageIO

/// Dimensioni in pixel (CMVideoDimensions non è Hashable).
struct Dim: Hashable {
    let w: Int32
    let h: Int32

    init(_ d: CMVideoDimensions) { w = d.width; h = d.height }

    var cm: CMVideoDimensions { CMVideoDimensions(width: w, height: h) }
    var pixels: Int { Int(w) * Int(h) }
    var megapixels: String { String(format: "%.1f MP", Double(pixels) / 1_000_000) }
    var label: String { "\(w)×\(h) (\(megapixels))" }
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

func megabytes(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

func seconds(_ s: Double) -> String {
    String(format: "%.2f s", s)
}

func deviceModelIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}

extension ProcessInfo.ThermalState {
    var italian: String {
        switch self {
        case .nominal: return "normale"
        case .fair: return "tiepido"
        case .serious: return "CALDO"
        case .critical: return "CRITICO"
        @unknown default: return "sconosciuto"
        }
    }
}

/// Temperatura e batteria (da chiamare sul main thread).
func deviceStatus() -> String {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let level = device.batteryLevel < 0 ? "?" : "\(Int(device.batteryLevel * 100))%"
    let state: String
    switch device.batteryState {
    case .charging: state = "in carica"
    case .full: state = "carica completa"
    case .unplugged: state = "a batteria"
    default: state = "stato sconosciuto"
    }
    return "temperatura \(ProcessInfo.processInfo.thermalState.italian), batteria \(level) \(state)"
}

struct ImageInfo {
    let width: Int
    let height: Int
    let orientation: Int
}

func imageInfo(_ data: Data) -> ImageInfo? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    return ImageInfo(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                     height: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
                     orientation: props[kCGImagePropertyOrientation] as? Int ?? 1)
}

func uiOrientation(exif: Int) -> UIImage.Orientation {
    switch exif {
    case 2: return .upMirrored
    case 3: return .down
    case 4: return .downMirrored
    case 5: return .leftMirrored
    case 6: return .right
    case 7: return .rightMirrored
    case 8: return .left
    default: return .up
    }
}

func makeThumbnail(_ data: Data, maxPixels: Int) -> UIImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

/// Ritaglio centrale a piena risoluzione (1 pixel della foto = 1 pixel dello schermo),
/// per giudicare il dettaglio reale.
func makeCenterCrop(_ data: Data, size: Int, orientation: Int) -> UIImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let side = min(size, full.width, full.height)
    let rect = CGRect(x: (full.width - side) / 2, y: (full.height - side) / 2, width: side, height: side)
    guard let cropped = full.cropping(to: rect) else { return nil }
    let oriented = UIImage(cgImage: cropped, scale: 1, orientation: uiOrientation(exif: orientation))
    // Ridisegna in una nuova immagine per applicare l'orientamento e liberare la foto intera.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: oriented.size, format: format).image { _ in
        oriented.draw(at: .zero)
    }
}

func photosDirectory() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Foto", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
