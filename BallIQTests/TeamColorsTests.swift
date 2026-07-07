import XCTest
import SwiftUI
@testable import BallIQ

/// Guards `TeamPalette.onSecondary` legibility — the result-reveal grade chip paints its text
/// in this color over `secondary`, so it must be computed from `secondary`'s own luminance,
/// not guessed by inverting `onPrimary`. That inversion assumes primary/secondary are always
/// opposite-luminance, which breaks for any team where both trend dark (or both trend light):
/// Carolina's teal primary (dark -> white text) pairs with a near-black secondary (also wants
/// white text) -- the inverted guess flipped to black-on-near-black, exactly the illegible
/// chip seen in the K4C4 result reveal for CAR/Christian McCaffrey.
final class TeamColorsTests: XCTestCase {

    func testOnSecondaryIsComputedFromSecondaryNotInvertedFromPrimary() {
        // Carolina: primary 0x0085CA (dark enough -> white onPrimary) and secondary
        // 0x101820 (near-black) BOTH want white text -- same luminance direction, the exact
        // shape an inverted-from-onPrimary guess gets backwards.
        let car = TeamColors.palette(sport: .nfl, abbr: "CAR")
        XCTAssertEqual(car.onPrimary, .white)
        XCTAssertEqual(car.onSecondary, .white, "near-black secondary must still get white text")

        // Detroit Pistons: primary 0xC8102E (dark red -> white) and secondary 0x1D42BA
        // (dark blue) -- same shape, second independent regression example.
        let det = TeamColors.palette(sport: .nba, abbr: "DET")
        XCTAssertEqual(det.onPrimary, .white)
        XCTAssertEqual(det.onSecondary, .white, "dark-on-dark pairing must still get white text")
    }

    func testOnSecondaryStillFlipsBlackOnALightSecondary() {
        // Green Bay: secondary 0xFFB612 is a bright gold -- legibly needs black text
        // regardless of primary. Confirms the fix didn't just hardcode "always white".
        let gb = TeamColors.palette(sport: .nfl, abbr: "GB")
        XCTAssertEqual(gb.onSecondary, Color(hex: 0x15120B))
    }

    func testFallbackPaletteHasBothLegibilityColors() {
        XCTAssertEqual(TeamColors.fallback.onPrimary, .white)
        XCTAssertEqual(TeamColors.fallback.onSecondary, .white)
    }
}
