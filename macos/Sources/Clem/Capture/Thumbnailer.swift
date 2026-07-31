import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Downscales kept frames to 480px-wide HEIC thumbnails (~15-30 KB) for the
/// timeline UI. The full-resolution frame is never written to disk.
enum Thumbnailer {
    static var thumbsDir: URL {
        let dir = Store.dataDir.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(image: CGImage, quality: Double) -> String? {
        let targetWidth = 480.0
        let scale = targetWidth / Double(image.width)
        let w = Int(targetWidth)
        let h = Int(Double(image.height) * scale)

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }

        let name = "thumb-\(Int(Date().timeIntervalSince1970 * 1000)).heic"
        let url = thumbsDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return name
    }
}
