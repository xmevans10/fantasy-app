import XCTest
@testable import BallIQ

/// Regression coverage for the bug where a free-form (Vibes or custom-rule) Keep4 mixing
/// positions in one pool baked the sport's generic top-3 stats onto every card regardless
/// of the season's actual position — a QB card reading "Rec Yds 0 / Rec TD 0 / Rec 0"
/// because the NFL catalog's first three entries are receiving stats, or a workhorse RB's
/// card leading with a near-empty receiving line ahead of the rushing yards that actually
/// defined the season. `displayColumns` now fills from `Sport.positionStatTemplates` — an
/// explicit default stat sheet per position — before ever falling back to the sport's
/// generic top-3 slice.
final class ScoringStatTests: XCTestCase {

    func testQBGetsPassingStatsNotReceiving() {
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "QB")
        XCTAssertEqual(cols.map(\.key),
                       ["passing_yards", "passing_tds", "interceptions", "rushing_yards", "rushing_tds",
                        "completions", "attempts", "completion_pct"])
        for col in cols {
            XCTAssertFalse(col.key.hasPrefix("receiving"), "QB card should never show \(col.key)")
        }
    }

    func testWRStillGetsReceivingStats() {
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "WR")
        XCTAssertEqual(cols.map(\.key),
                       ["receiving_yards", "receptions", "receiving_tds", "ypr", "targets"])
    }

    /// The actual bug behind "community puzzles don't show the relevant stats": a workhorse
    /// RB's card used to lead with receiving stats (0-ish for a pure rusher) because the NFL
    /// catalog lists receiving before rushing. The template leads with rushing for RBs, and
    /// (matching the daily pipeline's own RB themes) includes receptions, not just yards/TDs.
    func testRBLeadsWithRushingNotReceiving() {
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "RB")
        XCTAssertEqual(cols.map(\.key),
                       ["rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds",
                        "receptions", "ypc"])
    }

    func testBaseballPitcherGetsPitchingStatsNotHitting() {
        let cols = ScoringStat.displayColumns(sport: .baseball, position: "P")
        for col in cols {
            XCTAssertFalse(["hits", "doubles", "triples", "avg"].contains(col.key),
                           "pitcher card should never show hitting stat \(col.key)")
        }
    }

    /// Goalkeeper shares DF's exact 4-column template (clean sheets, apps, goals, assists),
    /// clean sheets first — matching the daily pipeline's `soccer-defenders` theme, which
    /// never slices by position at all (only NFL themes do); inventing a keeper-specific
    /// 2-column subset would diverge from what a daily puzzle actually shows.
    func testSoccerGoalkeeperGetsCleanSheetsNotGoals() {
        let cols = ScoringStat.displayColumns(sport: .soccer, position: "GK")
        XCTAssertEqual(cols.map(\.key), ["clean_sheets", "appearances", "goals", "assists"])
    }

    func testUnknownPositionFallsBackToSportGeneric() {
        let unknown = ScoringStat.displayColumns(sport: .nfl, position: "LB")
        XCTAssertEqual(unknown.map(\.key), ScoringStat.catalog(for: .nfl).prefix(3).map(\.key))
        // A recognized-but-different-family position (QB) must still diverge from the
        // unknown-position fallback — the interesting case unknown-vs-WR doesn't cover,
        // since the NFL catalog's generic top 3 happen to already be receiving stats.
        let qb = ScoringStat.displayColumns(sport: .nfl, position: "QB")
        XCTAssertNotEqual(unknown.map(\.key), qb.map(\.key))
    }

    func testNBAHasNoFamiliesSoAllPositionsGetTheSameGeneric() {
        let center = ScoringStat.displayColumns(sport: .nba, position: "C")
        let guard_ = ScoringStat.displayColumns(sport: .nba, position: "G")
        XCTAssertEqual(center.map(\.key), guard_.map(\.key))
    }

    /// Preferred keys (an active scoring rule's own terms) are tried first, but still get
    /// sliced to the position — a QB under a skill-position rule falls through to the QB
    /// generic defaults rather than keeping the rule's (inapplicable) receiving terms.
    func testPreferredKeysAreSlicedToPositionNotUsedBlindly() {
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "QB",
                                              preferredKeys: ["receiving_yards", "receiving_tds", "receptions"])
        for col in cols {
            XCTAssertFalse(col.key.hasPrefix("receiving"))
        }
    }

    func testPreferredKeysThatDoMatchPositionAreUsed() {
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "QB",
                                              preferredKeys: ["passing_yards", "passing_tds", "interceptions"])
        XCTAssertEqual(cols.map(\.key), ["passing_yards", "passing_tds", "interceptions"])
    }
}
