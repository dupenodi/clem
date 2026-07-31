import CoreGraphics
import Foundation

/// Perceptual dedupe: 64-bit dHash + Hamming distance against a rolling
/// window of recently kept hashes (catches A→B→A window flipping).
final class DedupeService {
    private var recent: [UInt64] = []
    private let windowSize = 5
    var hammingThreshold = 10

    /// dHash: grayscale 9×8, compare horizontally adjacent pixels.
    func dHash(of image: CGImage) -> UInt64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if pixels[y * w + x] > pixels[y * w + x + 1] {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    func isDuplicate(_ hash: UInt64) -> Bool {
        recent.contains { ($0 ^ hash).nonzeroBitCount < hammingThreshold }
    }

    func remember(_ hash: UInt64) {
        recent.append(hash)
        if recent.count > windowSize { recent.removeFirst() }
    }
}

enum TextSimilarity {
    /// Jaccard similarity over normalized word sets.
    static func jaccard(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let setB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        if setA.isEmpty && setB.isEmpty { return 1 }
        if setA.isEmpty || setB.isEmpty { return 0 }
        let inter = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(inter) / Double(union)
    }
}
