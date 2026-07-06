import XCTest
@testable import BallIQ

/// The scoring-type indicator: how a puzzle's grading philosophy (objective fantasy points vs
/// era-adjusted vs a community author's custom rule) is classified and resolved for display.
final class ScoringKindTests: XCTestCase {

    private func puzzle(theme: String, scoring: ScoringKind? = nil) -> Keep4Puzzle {
        Keep4Puzzle(id: "t", theme: theme, sport: .nfl, players: [], scoring: scoring)
    }

    private func theme(title: String, era: Bool) -> Keep4Theme {
        Keep4Theme(key: title, title: title, sport: .nfl, scale: "nfl_fantasy",
                   positions: ["QB"], minStats: [:],
                   columns: [], poolCap: 40, grain: "season", eraAdjusted: era)
    }

    // MARK: - Classification from the rule that graded the puzzle

    func testFantasyPresetIsPPR() {
        XCTAssertEqual(ScoringKind(rule: ScoringRule.preset("nfl_fantasy")!), .ppr)
        XCTAssertEqual(ScoringKind(rule: ScoringRule.preset("nba_fantasy")!), .ppr)
    }

    func testEraAdjustedFantasyIsEra() {
        XCTAssertEqual(ScoringKind(rule: ScoringRule.preset("nfl_fantasy")!.eraAdjusted(true)), .era)
    }

    func testHalfAndStandardPPRAreAlsoPPR() {
        // Reception-point variants are still objective fantasy totals, just different coefficients.
        XCTAssertEqual(ScoringKind(rule: ScoringRule.preset("nfl_fantasy_half")!), .ppr)
        XCTAssertEqual(ScoringKind(rule: ScoringRule.preset("nfl_fantasy_standard")!), .ppr)
    }

    // MARK: - Resolution on a puzzle

    func testBakedScoringWins() {
        // A baked value (written at community publish) beats any theme-title match.
        let themes = [theme(title: "My puzzle", era: true)]
        XCTAssertEqual(puzzle(theme: "My puzzle", scoring: .vibes).scoringKind(themes: themes), .vibes)
    }

    func testVibesRawValueStaysCustomForBackwardCompatibility() throws {
        // Already-published rows are baked with "custom" in Supabase — the Swift-side rename to
        // .vibes must not change the wire format.
        let json = #"{"id":"a","theme":"T","sport":"nfl","players":[],"scoring":"custom"}"#
        let decoded = try JSONDecoder().decode(Keep4Puzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.scoring, .vibes)
    }

    func testEraThemeTitleResolvesEra() {
        let themes = [theme(title: "Best seasons of all time — era-adjusted", era: true),
                      theme(title: "Elite WR receiving seasons", era: false)]
        XCTAssertEqual(puzzle(theme: "Best seasons of all time — era-adjusted")
            .scoringKind(themes: themes), .era)
        XCTAssertEqual(puzzle(theme: "Elite WR receiving seasons").scoringKind(themes: themes), .ppr)
    }

    func testUnknownThemeDefaultsToPPR() {
        // Generated niche themes ("2010s Day-3 RB steals…") aren't in the export but are
        // all fantasy-graded, as are legacy community rows — both default to PPR.
        XCTAssertEqual(puzzle(theme: "2010s Day-3 RB steals (round 5+)").scoringKind(themes: []), .ppr)
    }

    func testDecodingWithoutScoringKeyStaysNil() throws {
        // Additive + optional: existing baked content (no "scoring" key) decodes unchanged.
        let json = #"{"id":"a","theme":"T","sport":"nfl","players":[]}"#
        let decoded = try JSONDecoder().decode(Keep4Puzzle.self, from: Data(json.utf8))
        XCTAssertNil(decoded.scoring)
        XCTAssertEqual(decoded.scoringKind(themes: []), .ppr)
    }

    func testDecodingScoringKey() throws {
        let json = #"{"id":"a","theme":"T","sport":"nfl","players":[],"scoring":"era"}"#
        let decoded = try JSONDecoder().decode(Keep4Puzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.scoring, .era)
    }

    // MARK: - Display

    func testGradeUnit() {
        XCTAssertEqual(ScoringKind.ppr.gradeUnit, "PTS")
        XCTAssertEqual(ScoringKind.era.gradeUnit, "PTS")
    }

    func testBadgeLabelIsSportAware() {
        // "PPR" is an NFL term; NBA fantasy scoring isn't PPR.
        XCTAssertEqual(ScoringKind.ppr.badgeLabel(for: .nfl), "PPR")
        XCTAssertEqual(ScoringKind.ppr.badgeLabel(for: .nba), "FANTASY")
        XCTAssertEqual(ScoringKind.vibes.badgeLabel(for: .nfl), "VIBES")
    }

    func testVibesExplainerNamesTheAuthor() {
        XCTAssertTrue(ScoringKind.vibes.explainer(sport: .nfl, author: "xander").contains("@xander"))
        XCTAssertTrue(ScoringKind.vibes.explainer(sport: .nfl).contains("the author's"))
    }
}
