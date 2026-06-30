import SwiftUI

// "Prime Time" type system — heavy condensed broadcast caps.
// Display/hero: Anton (heavy condensed) + Saira Condensed Black/Bold.
// Body/UI: Saira. Uses weight + size extremes per the frontend-aesthetics guidance.
//
// Fonts are registered at launch (FontRegistration). Reference by PostScript name.

enum FontName {
    static let anton = "Anton-Regular"
    static let condBlack = "SairaCondensed-Black"
    static let condBold = "SairaCondensed-Bold"
    static let body = "Saira-Regular"
    static let bodyMedium = "Saira-SemiBold"
    static let bodyBold = "Saira-ExtraBold"
}

extension Font {
    // Hero / scoreboard numerals — the loudest moment on screen.
    static func hero(_ size: CGFloat) -> Font { .custom(FontName.anton, fixedSize: size) }

    // Condensed display headlines (caps).
    static func display(_ size: CGFloat) -> Font { .custom(FontName.condBlack, size: size, relativeTo: .largeTitle) }

    // MARK: Semantic tokens (replace the old CDS tokens; same names so views keep compiling)
    static let heroNumber  = Font.custom(FontName.anton, fixedSize: 72)   // big score reveal
    static let scoreReveal = Font.custom(FontName.anton, fixedSize: 64)   // CountUpText default
    static let scoreMedium = Font.custom(FontName.anton, fixedSize: 40)
    static let display1    = Font.custom(FontName.condBlack, size: 30, relativeTo: .largeTitle)
    static let title       = Font.custom(FontName.condBlack, size: 22, relativeTo: .title)
    static let heading     = Font.custom(FontName.condBold, size: 19, relativeTo: .title3)
    static let body14      = Font.custom(FontName.body, size: 15, relativeTo: .body)
    static let bodyStrong  = Font.custom(FontName.bodyMedium, size: 15, relativeTo: .body)
    static let label12     = Font.custom(FontName.bodyMedium, size: 12, relativeTo: .caption)
    static let label11     = Font.custom(FontName.bodyMedium, size: 11, relativeTo: .caption2)
    static let statValue   = Font.custom(FontName.bodyBold, size: 15, relativeTo: .body)
}
