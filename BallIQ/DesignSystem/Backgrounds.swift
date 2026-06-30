import SwiftUI

/// Faint diagonal "speed lines" — broadcast/arcade atmosphere behind hero areas.
struct SpeedLines: View {
    var color: Color = .ink
    var opacity: Double = 0.05
    var spacing: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                var x: CGFloat = -size.height
                while x < size.width {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(p, with: .color(color.opacity(opacity)), lineWidth: 6)
                    x += spacing
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// A bold color block with a diagonal cut at the bottom — broadcast lower-third energy.
struct DiagonalBlock: Shape {
    var cut: CGFloat = 24
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A soft radial glow used behind hero numbers.
struct HeroGlow: View {
    var color: Color
    var body: some View {
        RadialGradient(colors: [color.opacity(0.45), color.opacity(0)],
                       center: .center, startRadius: 4, endRadius: 180)
            .allowsHitTesting(false)
    }
}
