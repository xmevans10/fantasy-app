import XCTest
@testable import BallIQ

/// The scoring-formula explainer's data layer: resolving a puzzle to the exact point table
/// it was graded with, and the plain-English per-unit formatting.
final class ScoringBreakdownTests: XCTestCase {

    private func puzzle(theme: String = "Custom title", sport: Sport = .nfl,
                        scale: String? = nil) -> Keep4Puzzle {
        Keep4Puzzle(id: "t", theme: theme, sport: sport, players: [], scale: scale)
    }

    /// Every bundled daily theme must resolve to a formula section — a new theme whose scale
    /// has no Swift points-preset would silently fall back to the sport default, showing
    /// players the wrong formula. Fail loudly here instead.
    func testEveryBundledThemeScaleResolves() {
        let themes = Keep4Theme.bundled
        XCTAssertFalse(themes.isEmpty)
        for theme in themes {
            let section = ScoringBreakdown.section(scale: theme.scale, sport: theme.sport,
                                                   heading: nil)
            XCTAssertNotNil(section, "no formula section for theme \(theme.key) (scale \(theme.scale))")
        }
    }

    /// Daily puzzles carry their theme title; the breakdown must pick that theme's exact
    /// scale (a QB theme shows the QB formula, not unified NFL fantasy).
    func testDailyThemeTitleResolvesExactScale() {
        guard let qbTheme = Keep4Theme.bundled.first(where: { $0.scale == "nfl_qb_fantasy" }) else {
            return XCTFail("no QB theme in bundle")
        }
        let breakdown = ScoringBreakdown(puzzle: puzzle(theme: qbTheme.title, sport: .nfl))
        XCTAssertTrue(breakdown.exact)
        XCTAssertEqual(breakdown.sections.map(\.scaleKey), ["nfl_qb_fantasy"])
        // No receiving terms in the QB formula.
        XCTAssertFalse(breakdown.sections[0].rows.contains { $0.stat == "receptions" })
    }

    /// A baked scale key (community publish) wins over everything and surfaces the variant —
    /// half-PPR must show receptions at 0.5, not full PPR's 1.0.
    func testBakedScaleWins() {
        let breakdown = ScoringBreakdown(puzzle: puzzle(sport: .nfl, scale: "nfl_fantasy_half"))
        XCTAssertTrue(breakdown.exact)
        let receptions = breakdown.sections[0].rows.first { $0.stat == "receptions" }
        XCTAssertEqual(receptions?.points, 0.5)
    }

    /// Single-game scales reuse season coefficients under a `_game` suffix (grade.py alias).
    func testGameScaleSuffixResolves() {
        let breakdown = ScoringBreakdown(puzzle: puzzle(sport: .nfl, scale: "nfl_skill_ppr_game"))
        XCTAssertTrue(breakdown.exact)
        XCTAssertEqual(breakdown.sections.map(\.scaleKey), ["nfl_skill_ppr"])
    }

    /// Legacy community rows (no baked scale, custom title) fall back to the sport defaults —
    /// both role formulas for the two-formula sports.
    func testLegacyFallbackShowsRoleSections() {
        let breakdown = ScoringBreakdown(puzzle: puzzle(sport: .baseball))
        XCTAssertFalse(breakdown.exact)
        XCTAssertEqual(breakdown.sections.map(\.scaleKey),
                       ["baseball_hitter_fantasy", "baseball_pitcher_fantasy"])
        XCTAssertEqual(breakdown.sections.map(\.heading), ["Hitters", "Pitchers"])
    }

    /// Rows must mirror the preset coefficients exactly (the sheet reads the real formula,
    /// never a re-hardcoded copy).
    func testRowsMirrorPresetCoefficients() {
        let breakdown = ScoringBreakdown(puzzle: puzzle(sport: .tennis, scale: "tennis_fantasy"))
        let rows = Dictionary(uniqueKeysWithValues: breakdown.sections[0].rows.map { ($0.stat, $0.points) })
        XCTAssertEqual(rows, ["matches_won": 1.0, "titles": 8.0,
                              "grand_slams": 30.0, "matches_lost": -0.5])
    }

    /// base_on_balls means "walk" for hitters but "walk allowed" for pitchers.
    func testWalkLabelDisambiguatesByRole() {
        let hitter = ScoringBreakdown.section(scale: "baseball_hitter_fantasy", sport: .baseball, heading: nil)
        let pitcher = ScoringBreakdown.section(scale: "baseball_pitcher_fantasy", sport: .baseball, heading: nil)
        XCTAssertEqual(hitter?.rows.first { $0.stat == "base_on_balls" }?.label, "Walk")
        XCTAssertEqual(pitcher?.rows.first { $0.stat == "base_on_balls" }?.label, "Walk allowed")
    }

    func testPointsTextFormatting() {
        XCTAssertEqual(ScoringBreakdown.pointsText(0.04), "+1 per 25")   // passing yards
        XCTAssertEqual(ScoringBreakdown.pointsText(0.1), "+1 per 10")    // rec/rush yards
        XCTAssertEqual(ScoringBreakdown.pointsText(0.5), "+0.5")         // half-PPR receptions
        XCTAssertEqual(ScoringBreakdown.pointsText(1), "+1")
        XCTAssertEqual(ScoringBreakdown.pointsText(1.2), "+1.2")         // NBA rebounds
        XCTAssertEqual(ScoringBreakdown.pointsText(6), "+6")             // TDs
        XCTAssertEqual(ScoringBreakdown.pointsText(-2), "−2")            // INTs
        XCTAssertEqual(ScoringBreakdown.pointsText(-0.5), "−0.5")        // walks allowed
    }
}
