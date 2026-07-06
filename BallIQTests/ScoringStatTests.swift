import XCTest
@testable import BallIQ

/// Regression coverage for the bug where a free-form (Vibes or custom-rule) Keep4 mixing
/// positions in one pool baked the sport's generic top-3 stats onto every card regardless
/// of the season's actual position — a QB card reading "Rec Yds 0 / Rec TD 0 / Rec 0"
/// because the NFL catalog's first three entries are receiving stats. `displayColumns`
/// shares `Sport.positionStatFamilies` with `Keep4Theme.columns(for:)` so both the
/// theme-templated and free-form creation paths get the same guarantee.
final class ScoringStatTests: XCTestCase {

    func testQBGetsPassingStatsNotReceiving() {
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "QB")
        XCTAssertEqual(cols.count, 3)
        for col in cols {
            XCTAssertFalse(col.key.hasPrefix("receiving"), "QB card should never show \(col.key)")
        }
        XCTAssertTrue(cols.contains { $0.key.hasPrefix("passing_") })
    }

    func testWRStillGetsReceivingStats() {
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "WR")
        XCTAssertEqual(cols.map(\.key), ["receiving_yards", "receiving_tds", "receptions"])
    }

    func testBaseballPitcherGetsPitchingStatsNotHitting() {
        let cols = ScoringStat.displayColumns(sport: .baseball, position: "P")
        for col in cols {
            XCTAssertFalse(["hits", "doubles", "triples", "avg"].contains(col.key),
                           "pitcher card should never show hitting stat \(col.key)")
        }
    }

    /// Goalkeeper's own family (appearances, clean_sheets) is only 2 stats wide — the third
    /// slot pads from the sport's remaining stats rather than reverting to the unsliced
    /// catalog outright, so clean_sheets still outranks goals/assists on a keeper's card.
    func testSoccerGoalkeeperGetsCleanSheetsNotGoals() {
        let cols = ScoringStat.displayColumns(sport: .soccer, position: "GK")
        XCTAssertEqual(cols.count, 3)
        XCTAssertTrue(cols.contains { $0.key == "clean_sheets" })
        XCTAssertTrue(cols.contains { $0.key == "appearances" })
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
