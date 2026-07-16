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
        XCTAssertEqual(cols.map(\.key), ["receiving_yards", "receptions", "receiving_tds"])
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

    /// Goalkeeper gets its own narrower template than DF — clean sheets + appearances only.
    /// Goals/assists are never an obvious keeper stat even though the daily pipeline's
    /// `soccer-defenders` theme (which covers both DF and GK, since only NFL themes slice by
    /// position at all) shows all 4 columns to both.
    func testSoccerGoalkeeperGetsCleanSheetsNotGoals() {
        let cols = ScoringStat.displayColumns(sport: .soccer, position: "GK")
        XCTAssertEqual(cols.map(\.key), ["clean_sheets", "appearances"])
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

    /// The same bug, reached through free-form creation's "PPR" preset instead of Vibes:
    /// `nfl_fantasy` (the unified cross-position formula real puzzles use) declares its terms
    /// receiving-before-rushing for scoring-parity with grade.py, not display prominence. A
    /// PPR-scored workhorse RB used to show "Rec/Rec Yds/Rec TD" (its first 3 declared,
    /// position-matching terms) instead of the rushing line that actually defined the season.
    /// Scored terms must be re-ordered by the position's own template, not kept in raw
    /// declaration order.
    func testPPRPresetScoredRBLeadsWithRushingNotDeclarationOrder() {
        let nflFantasyTerms = ["passing_yards", "passing_tds", "interceptions", "receptions",
                               "receiving_yards", "receiving_tds", "rushing_yards", "rushing_tds"]
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "RB", preferredKeys: nflFantasyTerms)
        XCTAssertEqual(cols.map(\.key), ["rushing_yards", "rushing_tds", "receiving_yards"])
    }

    /// Same preset, QB side: the rule scores passing/rushing/interceptions but not
    /// completions/attempts/completion_pct, so those get dropped rather than padding the
    /// card with unscored stats.
    func testPPRPresetScoredQBShowsOnlyScoredStats() {
        let nflFantasyTerms = ["passing_yards", "passing_tds", "interceptions", "receptions",
                               "receiving_yards", "receiving_tds", "rushing_yards", "rushing_tds"]
        let cols = ScoringStat.displayColumns(sport: .nfl, position: "QB", preferredKeys: nflFantasyTerms)
        XCTAssertEqual(cols.map(\.key), ["passing_yards", "passing_tds", "interceptions"])
    }

    // MARK: - Single-game grain (single-game puzzle creation)

    /// The exact bug this whole grain param exists to prevent: an NBA single-game row
    /// carries raw totals (`points`/`rebounds`/...), not the season's per-game rates
    /// (`ppg`/`rpg`/...). Defaulting to the season template would read absent keys and
    /// silently render every stat as zero.
    func testNBASingleGameUsesRawTotalsNotPerGameRates() {
        let cols = ScoringStat.displayColumns(sport: .nba, position: "G", grain: .singleGame)
        XCTAssertEqual(cols.map(\.key), ["points", "assists", "rebounds"])
        for col in cols {
            XCTAssertFalse(col.key.hasSuffix("pg"), "single-game NBA card should never show a per-game rate")
        }
    }

    func testNBASeasonGrainStillUsesGenericFallbackUnaffected() {
        // Explicit .season (the default) must be untouched by the new game-grain override —
        // NBA still has no season template, same as before this change.
        let center = ScoringStat.displayColumns(sport: .nba, position: "C", grain: .season)
        let guard_ = ScoringStat.displayColumns(sport: .nba, position: "G", grain: .season)
        XCTAssertEqual(center.map(\.key), guard_.map(\.key))
    }

    /// Baseball's season template shows the rate stats `avg`/`era` — neither is emitted for
    /// a single game (see `mlb_stats_games.py`) — so the game-grain override swaps them for
    /// counting stats the game rows do carry.
    func testBaseballSingleGameSwapsRateStatsForCountingStats() {
        let hitter = ScoringStat.displayColumns(sport: .baseball, position: "H", grain: .singleGame)
        XCTAssertEqual(hitter.map(\.key), ["home_runs", "rbi", "hits"])
        let pitcher = ScoringStat.displayColumns(sport: .baseball, position: "P", grain: .singleGame)
        XCTAssertEqual(pitcher.map(\.key), ["strike_outs", "earned_runs", "innings_pitched"])
    }

    /// NFL has no game-grain override — a game row's `rushing_yards` etc. are the exact
    /// same field names as a season row's, so the season template already works unchanged.
    func testNFLSingleGameFallsBackToSameSeasonTemplate() {
        let seasonCols = ScoringStat.displayColumns(sport: .nfl, position: "RB", grain: .season)
        let gameCols = ScoringStat.displayColumns(sport: .nfl, position: "RB", grain: .singleGame)
        XCTAssertEqual(seasonCols.map(\.key), gameCols.map(\.key))
    }
}
