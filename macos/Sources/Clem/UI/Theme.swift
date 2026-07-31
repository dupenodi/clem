import AppKit
import CoreImage
import SwiftUI

/// Are.na-inspired design language: quiet, monochrome, editorial. Near-black
/// neutral surfaces, hairline borders, restrained sans type, whitespace, and
/// colour used sparingly (a single muted link-blue). Content leads; chrome recedes.
enum Theme {
    // surfaces — warm neutral, nearly monochrome
    static let bg = Color(hex: "#111110")
    static let bgHi = Color(hex: "#171715")
    static let surface = Color(hex: "#1A1A18")
    static let surfaceHi = Color(hex: "#232320")

    // warm accent pair (the flames) over black
    static let accent = Color(hex: "#F96F1D") // primary orange
    static let accent2 = Color(hex: "#FDA81D") // amber
    // `gold`/`rose` kept as names other views reference; mapped onto the
    // warm accents so the whole app shifts consistently.
    static let gold = Color(hex: "#FDA81D")
    static let rose = Color(hex: "#F96F1D")

    // ink
    static let ink = Color(hex: "#ECEAE3")
    static func ink(_ o: Double) -> Color { ink.opacity(o) }
    static let line = Color.white.opacity(0.10)

    /// Headings use Ovo (bundled serif); body/UI uses the system sans.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Ovo", size: size)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A tiled film-grain / noise texture, generated once and cached. Built as a
/// raw RGBA bitmap so the grain is crisp (per-pixel), not blurred.
enum Noise {
    static let image: NSImage = make()
    private static func make() -> NSImage {
        let side = 160
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            // white speckle; visible density + alpha so it reads on black
            let lit = Double.random(in: 0...1) < 0.45
            let a = lit ? UInt8(Double.random(in: 0...255) * 0.9) : 0
            let v: UInt8 = 255
            pixels[i * 4 + 0] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = a
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        )!
        memcpy(rep.bitmapData!, pixels, pixels.count)
        let img = NSImage(size: NSSize(width: side, height: side))
        img.addRepresentation(rep)
        return img
    }
}

/// Flat near-monochrome backdrop with a film-grain overlay so large black
/// areas have texture (Are.na / editorial). Additive blend so grain reads on
/// black. `grainy: false` gives the plain flat backdrop (used on Home, where
/// the hero text and optional background image want a clean surface).
struct MarbleBackground: View {
    var grainy = true
    var body: some View {
        Theme.bg
            .overlay {
                if grainy {
                    Image(nsImage: Noise.image)
                        .resizable(resizingMode: .tile)
                        .opacity(0.06)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
    }
}

/// Fine monochrome film grain, generated once and tiled. Laid over flat dark
/// surfaces at low opacity it reads as paper/photographic noise.
enum Grain {
    static let tile: NSImage = {
        let size = CGRect(x: 0, y: 0, width: 256, height: 256)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .cropped(to: size),
            let cg = CIContext().createCGImage(noise, from: size)
        else { return NSImage(size: NSSize(width: 256, height: 256)) }
        return NSImage(cgImage: cg, size: NSSize(width: 256, height: 256))
    }()
}

extension View {
    /// Noisy-surface overlay; pass the surface's corner radius so the grain
    /// stays inside rounded cards. Purely decorative — never intercepts clicks.
    func grain(_ opacity: Double = 0.05, cornerRadius: CGFloat = 0) -> some View {
        overlay(
            Image(nsImage: Grain.tile)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .allowsHitTesting(false)
        )
    }
}

/// A flat bordered block — the Are.na "card": hairline border, no fill glow.
struct Tablet: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .grain(cornerRadius: 10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

extension View {
    func tablet(padding: CGFloat = 16) -> some View { modifier(Tablet(padding: padding)) }
}

/// User-chosen background image for the Home screen (optional).
enum HomeBackground {
    static var url: URL { Store.dataDir.appendingPathComponent("home-bg.png") }
    static var image: NSImage? {
        if let custom = NSImage(contentsOf: url) { return custom }
        if let bundled = Bundle.main.url(forResource: "home-bg-default", withExtension: "png") {
            return NSImage(contentsOf: bundled)
        }
        return nil
    }
    static func set(from source: URL) {
        if let data = try? Data(contentsOf: source) {
            try? data.write(to: url)
            NotificationCenter.default.post(name: .clemHomeBGChanged, object: nil)
        }
    }
    static func clear() {
        try? FileManager.default.removeItem(at: url)
        NotificationCenter.default.post(name: .clemHomeBGChanged, object: nil)
    }
}

extension Notification.Name {
    static let clemHomeBGChanged = Notification.Name("clemHomeBGChanged")
}
