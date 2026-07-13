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

    // MARK: - Backlog #8: defunct-franchise coverage from the 1950–2001 NBA / 1970–1998 NFL
    // historical sweeps (`bref_nba.py` / `nfl_history.py`). Before this fix every one of these
    // abbreviations fell through to `fallback` — a K4C4 card for, say, a 1985 Spurs season read
    // as an unbranded slate/blue card exactly like an unrecognized team would.

    /// Every abbreviation the historical providers can actually emit (confirmed against the
    /// committed `nba_bref_seasons.csv` / `nfl_history_seasons.csv`), minus the two multi-team
    /// codes ("3TM"/"4TM") that correctly stay on `fallback` — they're a traded-mid-season
    /// marker, not a real franchise, so a neutral card is the right outcome for them.
    func testAllHistoricalAbbreviationsResolveToRealPalettes() {
        let nfl = ["ARI", "ATL", "BAL", "BOS", "BUF", "CAR", "CHI", "CIN", "CLE", "DAL", "DEN",
                   "DET", "GB", "HOU", "IND", "JAX", "KC", "MIA", "MIN", "NE", "NO", "NYG", "NYJ",
                   "OAK", "PHI", "PHO", "PIT", "RAI", "RAM", "SD", "SEA", "SF", "STL", "TB", "TEN", "WAS"]
        for abbr in nfl {
            XCTAssertNotEqual(TeamColors.palette(sport: .nfl, abbr: abbr), TeamColors.fallback,
                               "\(abbr) (NFL 1970–1998 sweep) still falls back")
        }

        let nba = ["AND", "ATL", "BAL", "BLB", "BOS", "BUF", "CAP", "CHH", "CHI", "CHP", "CHS",
                   "CHZ", "CIN", "CLE", "DAL", "DEN", "DET", "DNN", "FTW", "GS", "HOU", "IND",
                   "INO", "KCK", "KCO", "LAC", "LAL", "MIA", "MIL", "MIN", "MLH", "MNL", "NJN",
                   "NOJ", "NY", "NYN", "ORL", "PHI", "PHW", "PHX", "POR", "ROC", "SA", "SAC",
                   "SDC", "SDR", "SEA", "SFW", "SHE", "STB", "STL", "SYR", "TOR", "TRI", "UTAH",
                   "VAN", "WAT", "WSB", "WSC", "WSH"]
        for abbr in nba {
            XCTAssertNotEqual(TeamColors.palette(sport: .nba, abbr: abbr), TeamColors.fallback,
                               "\(abbr) (NBA 1950–2001 sweep) still falls back")
        }
    }

    /// The two multi-team codes are the one deliberate exception — confirms the test above
    /// isn't accidentally vacuous (e.g. from a typo'd sport case that resolves everything).
    func testMultiTeamCodesStillFallBack() {
        XCTAssertEqual(TeamColors.palette(sport: .nfl, abbr: "3TM"), TeamColors.fallback)
        XCTAssertEqual(TeamColors.palette(sport: .nfl, abbr: "4TM"), TeamColors.fallback)
    }

    /// Franchise-continuity aliases resolve to the *current* team's real palette, not a
    /// lookalike — the whole point is that a 1994 Rockets card and a 1970 Rockets (nee San
    /// Diego) card should share one recognizable Houston red-and-black identity.
    func testFranchiseContinuityAliasesMatchCurrentTeamColors() {
        XCTAssertEqual(TeamColors.palette(sport: .nba, abbr: "SA"), TeamColors.palette(sport: .nba, abbr: "SAS"))
        XCTAssertEqual(TeamColors.palette(sport: .nba, abbr: "WSH"), TeamColors.palette(sport: .nba, abbr: "WAS"))
        XCTAssertEqual(TeamColors.palette(sport: .nba, abbr: "SYR"), TeamColors.palette(sport: .nba, abbr: "PHI"))
        XCTAssertEqual(TeamColors.palette(sport: .nba, abbr: "MNL"), TeamColors.palette(sport: .nba, abbr: "LAL"))
        XCTAssertEqual(TeamColors.palette(sport: .nba, abbr: "SDR"), TeamColors.palette(sport: .nba, abbr: "HOU"))
        XCTAssertEqual(TeamColors.palette(sport: .nba, abbr: "CHH"), TeamColors.palette(sport: .nba, abbr: "CHA"))
        XCTAssertEqual(TeamColors.palette(sport: .nba, abbr: "WSB"), TeamColors.palette(sport: .nba, abbr: "WAS"))
        XCTAssertEqual(TeamColors.palette(sport: .nfl, abbr: "PHO"), TeamColors.palette(sport: .nfl, abbr: "ARI"))
        XCTAssertEqual(TeamColors.palette(sport: .nfl, abbr: "RAI"), TeamColors.palette(sport: .nfl, abbr: "LV"))
        XCTAssertEqual(TeamColors.palette(sport: .nfl, abbr: "RAM"), TeamColors.palette(sport: .nfl, abbr: "LAR"))
        XCTAssertEqual(TeamColors.palette(sport: .nfl, abbr: "BOS"), TeamColors.palette(sport: .nfl, abbr: "NE"))
    }

    /// Fresh-color defunct franchises (no successor) still get *distinct* legible palettes,
    /// not just "anything non-fallback" — guards against them accidentally colliding with
    /// each other or with `fallback`'s own slate/blue.
    func testDefunctFranchisesWithNoSuccessorGetDistinctPalettes() {
        let codes = ["AND", "BLB", "CHS", "DNN", "INO", "SHE", "STB", "WAT", "WSC"]
        let palettes = codes.map { TeamColors.palette(sport: .nba, abbr: $0) }
        XCTAssertEqual(Set(palettes).count, palettes.count, "defunct franchises collided on the same palette")
        for palette in palettes {
            XCTAssertNotEqual(palette, TeamColors.fallback)
        }
    }
}
