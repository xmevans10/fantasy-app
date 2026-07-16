import SwiftUI

/// The official four-color Google "G" mark, drawn as vector paths (translated from Google's
/// canonical 18×18 identity SVG) so the sign-in buttons meet Google's branding guidelines
/// without bundling an image asset. Colors are Google's fixed brand palette — deliberately
/// NOT theme tokens; the mark must render identically in light/dark and every locale.
struct GoogleGMark: View {
    var size: CGFloat = 18

    private static let blue   = Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255)
    private static let green  = Color(red: 0x34 / 255, green: 0xA8 / 255, blue: 0x53 / 255)
    private static let yellow = Color(red: 0xFB / 255, green: 0xBC / 255, blue: 0x05 / 255)
    private static let red    = Color(red: 0xEA / 255, green: 0x43 / 255, blue: 0x35 / 255)

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height) / 18
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            // Blue: right lobe + crossbar
            var blue = Path()
            blue.move(to: pt(17.64, 9.2045))
            blue.addCurve(to: pt(17.4764, 7.3636), control1: pt(17.64, 8.5664), control2: pt(17.5827, 7.9527))
            blue.addLine(to: pt(9, 7.3636))
            blue.addLine(to: pt(9, 10.845))
            blue.addLine(to: pt(13.8436, 10.845))
            blue.addCurve(to: pt(12.0477, 13.5614), control1: pt(13.635, 11.97), control2: pt(13.0009, 12.9232))
            blue.addLine(to: pt(12.0477, 15.8195))
            blue.addLine(to: pt(14.9564, 15.8195))
            blue.addCurve(to: pt(17.64, 9.2045), control1: pt(16.6582, 14.2527), control2: pt(17.64, 11.9455))
            blue.closeSubpath()
            context.fill(blue, with: .color(Self.blue))

            // Green: bottom arc
            var green = Path()
            green.move(to: pt(9, 18))
            green.addCurve(to: pt(14.9564, 15.8195), control1: pt(11.43, 18), control2: pt(13.4673, 17.194))
            green.addLine(to: pt(12.0477, 13.5614))
            green.addCurve(to: pt(9, 14.4204), control1: pt(11.2418, 14.1014), control2: pt(10.2109, 14.4204))
            green.addCurve(to: pt(3.964, 10.71), control1: pt(6.656, 14.4204), control2: pt(4.6718, 12.8373))
            green.addLine(to: pt(0.9574, 10.71))
            green.addLine(to: pt(0.9574, 13.0418))
            green.addCurve(to: pt(9, 18), control1: pt(2.4382, 15.9832), control2: pt(5.4818, 18))
            green.closeSubpath()
            context.fill(green, with: .color(Self.green))

            // Yellow: left arc
            var yellow = Path()
            yellow.move(to: pt(3.964, 10.71))
            yellow.addCurve(to: pt(3.6818, 9), control1: pt(3.784, 10.17), control2: pt(3.6818, 9.5932))
            yellow.addCurve(to: pt(3.9641, 7.29), control1: pt(3.6818, 8.4068), control2: pt(3.7841, 7.83))
            yellow.addLine(to: pt(3.9641, 4.9582))
            yellow.addLine(to: pt(0.9573, 4.9582))
            yellow.addCurve(to: pt(0, 9), control1: pt(0.3477, 6.1732), control2: pt(0, 7.5477))
            yellow.addCurve(to: pt(0.9573, 13.0418), control1: pt(0, 10.4523), control2: pt(0.3477, 11.8268))
            yellow.addLine(to: pt(3.964, 10.71))
            yellow.closeSubpath()
            context.fill(yellow, with: .color(Self.yellow))

            // Red: top arc
            var red = Path()
            red.move(to: pt(9, 3.5795))
            red.addCurve(to: pt(12.4405, 4.9255), control1: pt(10.3214, 3.5795), control2: pt(11.5077, 4.0336))
            red.addLine(to: pt(15.0218, 2.3441))
            red.addCurve(to: pt(9, 0), control1: pt(13.4632, 0.8918), control2: pt(11.4259, 0))
            red.addCurve(to: pt(0.9573, 4.9582), control1: pt(5.4818, 0), control2: pt(2.4382, 2.0168))
            red.addLine(to: pt(3.964, 7.29))
            red.addCurve(to: pt(9, 3.5795), control1: pt(4.6718, 5.1627), control2: pt(6.6559, 3.5795))
            red.closeSubpath()
            context.fill(red, with: .color(Self.red))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // decorative; the button label carries the meaning
    }
}

#Preview {
    HStack(spacing: 20) {
        GoogleGMark(size: 18)
        GoogleGMark(size: 32)
        GoogleGMark(size: 64)
    }
    .padding()
}
