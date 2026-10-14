import SwiftUI
import UIKit

/// The app's page ground: `Color.appBackground` given the feel of printed stock instead of a flat
/// fill. Four quiet layers, all tinted with dynamic tokens so dark mode inverts with the palette:
/// a faint Prime-blue wash off the top edge (stadium light), a broadcast halftone that fans out
/// of the top-trailing corner, a fine paper grain, and a soft ink vignette at the foot.
///
/// Built to cost nothing while scrolling: the grain is one pre-rendered tile the GPU repeats, and
/// the halftone is a single `Canvas` that only redraws when the container's size changes. Content
/// scrolls *over* this view; nothing here is ever invalidated per frame.
struct PaperGround: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color.appBackground

            LinearGradient(colors: [Color.accentFill.opacity(dark ? 0.07 : 0.035), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))

            Halftone(opacity: dark ? 0.055 : 0.065)

            Image(uiImage: PaperGrain.tile)
                .renderingMode(.template)
                .resizable(resizingMode: .tile)
                .foregroundStyle(Color.ink)
                .opacity(dark ? 0.04 : 0.045)

            LinearGradient(colors: [.clear, Color.black.opacity(dark ? 0.3 : 0.04)],
                           startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Broadcast halftone: a dot grid whose dots shrink with distance from the top-trailing corner,
/// so the pattern reads as a printed fade rather than wallpaper. Gone by mid-screen, which keeps
/// it out from behind the dense lists and cards lower down.
private struct Halftone: View {
    var opacity: Double
    var pitch: CGFloat = 11
    var maxDot: CGFloat = 2.6

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            let origin = CGPoint(x: size.width, y: 0)
            let reach = max(size.width, 1) * 1.15
            var dots = Path()
            var y: CGFloat = pitch / 2
            var row = 0
            while y < reach {
                // Offset alternate rows like a real screen, so it doesn't read as graph paper.
                var x: CGFloat = size.width - (row.isMultiple(of: 2) ? 0 : pitch / 2)
                while x > size.width - reach {
                    let d = hypot(x - origin.x, y - origin.y) / reach
                    let r = maxDot * (1 - d) * (1 - d)
                    if r > 0.35 {
                        dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    }
                    x -= pitch
                }
                y += pitch * 0.87
                row += 1
            }
            ctx.fill(dots, with: .color(Color.ink.opacity(opacity)))
        }
    }
}

/// A seeded, pre-rendered alpha-noise tile, made once per process. Alpha-only so it can be drawn
/// as a template image and take the (dynamic) ink color, and seeded so the grain is identical on
/// every launch and in every screenshot.
private enum PaperGrain {
    static let tile: UIImage = {
        let side = 192
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x5EED_BA11
        for i in 0..<(side * side) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n = UInt8(truncatingIfNeeded: seed >> 56)
            // Square the noise so most pixels are near-clear and a few carry the fibre.
            let a = UInt8((Int(n) * Int(n)) >> 8)
            bytes[i * 4 + 3] = a
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return UIImage() }
        // Scale 2 keeps each grain pixel finer than a point without going sub-pixel on 3x screens.
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()
}

extension View {
    /// The shared page ground (see `PaperGround`). Use in place of `.background(Color.appBackground)`
    /// on full screens and sheets, so every page carries the same stock.
    func paperGround() -> some View {
        background { PaperGround().ignoresSafeArea() }
    }
}
