// Renders the Clem app icon: charcoal rounded square, dotted grid,
// a glowing mini-clem. Usage: swift make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// Big Sur style: rounded rect with margin (system adds the shadow).
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let rounded = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(rounded)
ctx.clip()

// warm charcoal gradient
let colors = [
    CGColor(red: 0.145, green: 0.135, blue: 0.125, alpha: 1),
    CGColor(red: 0.075, green: 0.07, blue: 0.065, alpha: 1),
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: size / 2, y: size), end: CGPoint(x: size / 2, y: 0), options: [])

// dotted grid
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
var gy = margin + 60.0
while gy < size - margin {
    var gx = margin + 60.0
    while gx < size - margin {
        ctx.fillEllipse(in: CGRect(x: gx, y: gy, width: 5, height: 5))
        gx += 88
    }
    gy += 88
}

// mini clem
let rose = CGColor(red: 0.85, green: 0.45, blue: 0.55, alpha: 1)
let gold = CGColor(red: 0.85, green: 0.64, blue: 0.25, alpha: 1)
let hub = CGPoint(x: 512, y: 540)
let nodes: [(CGPoint, CGColor, CGFloat)] = [
    (CGPoint(x: 300, y: 700), rose, 34),
    (CGPoint(x: 730, y: 690), gold, 34),
    (CGPoint(x: 285, y: 360), gold, 30),
    (CGPoint(x: 705, y: 330), rose, 38),
    (CGPoint(x: 540, y: 205), rose, 26),
]

// edges
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.75))
ctx.setLineWidth(7)
for (p, _, _) in nodes {
    ctx.move(to: hub)
    ctx.addLine(to: p)
}
ctx.strokePath()

func glowDot(_ p: CGPoint, _ color: CGColor, _ r: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 2.2, color: color.copy(alpha: 0.9))
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    ctx.restoreGState()
}

for (p, c, r) in nodes { glowDot(p, c, r) }

// hub ring (like a source node)
ctx.setFillColor(CGColor(red: 0.13, green: 0.12, blue: 0.115, alpha: 1))
ctx.fillEllipse(in: CGRect(x: hub.x - 108, y: hub.y - 108, width: 216, height: 216))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
ctx.setLineWidth(12)
ctx.strokeEllipse(in: CGRect(x: hub.x - 108, y: hub.y - 108, width: 216, height: 216))
glowDot(hub, rose, 46)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
