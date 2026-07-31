import SwiftUI

/// "Embers" — the Focus tab's ambient animation. Pale, grain-like dust (your
/// attention) drifts in slow orbits around a breathing amber core; every
/// ORANGE ember is one time something pulled you away today. The calmer the
/// day, the tighter the field draws to the core. Motion stays in the
/// periphery — slow, quiet, Are.na-restrained.
struct AttentionOrbit: View {
    var pulls: Int      // today's pull count → number of orange embers
    var score: Double   // 0…1 focus score → how tight the field orbits
    var locked: Bool    // focus session running → core swells

    /// Deterministic per-particle randomness (stable across frames).
    private static func rnd(_ i: Double) -> Double {
        let x = sin(i * 127.1 + 311.7) * 43758.5453
        return x - floor(x)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2 - 12

                // faint orbit rings
                for ring in [0.42, 0.68, 0.94] {
                    let r = maxR * ring
                    ctx.stroke(
                        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.96, width: r * 2, height: r * 1.92)),
                        with: .color(.white.opacity(0.04)), lineWidth: 1
                    )
                }

                // breathing amber core
                let breathe = 1 + 0.05 * sin(t * 0.7)
                let coreR = maxR * (locked ? 0.34 : 0.22) * breathe
                let glow = Gradient(stops: [
                    .init(color: Theme.accent2.opacity(locked ? 0.34 : 0.20), location: 0),
                    .init(color: Theme.accent.opacity(0.09), location: 0.55),
                    .init(color: .clear, location: 1),
                ])
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - coreR * 2, y: c.y - coreR * 2, width: coreR * 4, height: coreR * 4)),
                    with: .radialGradient(glow, center: c, startRadius: 0, endRadius: coreR * 2)
                )

                // particle field
                let n = 84
                let embers = min(max(pulls, 0), 26)
                let inner = 0.28 + 0.34 * (1 - score) // focused day → tighter orbit
                for i in 0..<n {
                    let fi = Double(i)
                    let isEmber = i < embers
                    let r1 = Self.rnd(fi), r2 = Self.rnd(fi + 57), r3 = Self.rnd(fi + 113)
                    let baseR = maxR * (inner + (0.94 - inner) * r1)
                    let dir: Double = r2 > 0.5 ? 1 : -1
                    let speed = (isEmber ? 0.14 : 0.045) * (0.6 + r3)
                    let angle = r2 * .pi * 2 + t * speed * dir
                    let wobble = isEmber ? sin(t * 1.1 + fi) * 5 : sin(t * 0.35 + fi) * 2
                    let r = baseR + wobble
                    let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r * 0.96)
                    let d: CGFloat = isEmber ? 2.6 : 1.5
                    let twinkle = 0.55 + 0.45 * sin(t * (0.5 + r3) + fi * 2)
                    let color: Color = isEmber
                        ? Theme.accent.opacity(0.35 + 0.45 * twinkle)
                        : .white.opacity(0.08 + 0.22 * twinkle)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                        with: .color(color)
                    )
                }
            }
        }
    }
}
