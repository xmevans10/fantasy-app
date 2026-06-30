import SwiftUI

/// CDS color ramps — 7 stops per hue (50 lightest … 900 darkest), exact CDS hex values.
/// These are the raw palette; semantic role tokens (Tokens.swift) map onto them.
struct Ramp {
    let s50, s100, s200, s400, s600, s800, s900: Color

    init(_ h50: UInt32, _ h100: UInt32, _ h200: UInt32, _ h400: UInt32,
         _ h600: UInt32, _ h800: UInt32, _ h900: UInt32) {
        s50 = Color(hex: h50); s100 = Color(hex: h100); s200 = Color(hex: h200)
        s400 = Color(hex: h400); s600 = Color(hex: h600); s800 = Color(hex: h800); s900 = Color(hex: h900)
    }
}

enum Palette {
    static let blue   = Ramp(0xE6F1FB, 0xB5D4F4, 0x85B7EB, 0x378ADD, 0x185FA5, 0x0C447C, 0x042C53)
    static let green  = Ramp(0xEAF3DE, 0xC0DD97, 0x97C459, 0x639922, 0x3B6D11, 0x27500A, 0x173404)
    static let amber  = Ramp(0xFAEEDA, 0xFAC775, 0xEF9F27, 0xBA7517, 0x854F0B, 0x633806, 0x412402)
    static let red    = Ramp(0xFCEBEB, 0xF7C1C1, 0xF09595, 0xE24B4A, 0xA32D2D, 0x791F1F, 0x501313)
    static let purple = Ramp(0xEEEDFE, 0xCECBF6, 0xAFA9EC, 0x7F77DD, 0x534AB7, 0x3C3489, 0x26215C)
    static let gray   = Ramp(0xF1EFE8, 0xD3D1C7, 0xB4B2A9, 0x888780, 0x5F5E5A, 0x444441, 0x2C2C2A)
}
