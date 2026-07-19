import XCTest
@testable import BallIQ

/// M10 template-unification parity: the Swift-decoded theme catalog must match
/// `tools/ingest/themes.py` `KEEP4_THEMES` (locked on the Python side by
/// `test_export_themes.py` against the same bundled `keep4_themes.json`).
final class Keep4ThemeTests: XCTestCase {

    private let themes = Keep4Theme.loadBundled()

    func testBundleDecodesAllThemes() {
        XCTAssertEqual(themes.count, 42, "bundled keep4_themes.json out of sync with themes.py")
        XCTAssertEqual(Set(themes.map(\.key)).count, themes.count, "duplicate theme keys")
    }

    func testEraThemeDecodesWithFlag() throws {
        let era = try XCTUnwrap(themes.first { $0.key == "nfl-total-fantasy-era" })
        XCTAssertTrue(era.eraAdjusted)
        XCTAssertTrue(era.isCreatable)
        XCTAssertEqual(era.scale, "nfl_fantasy")
        // Every other theme is raw points.
        XCTAssertTrue(themes.filter(\.eraAdjusted).count == 1)
    }

    /// Locked-value mirror of test_export_themes.py::test_export_shape_locked_value.
    func testWRThemeLockedValue() throws {
        let t = try XCTUnwrap(themes.first { $0.key == "nfl-wr-receiving" })
        XCTAssertEqual(t.title, "Elite WR receiving seasons")
        XCTAssertEqual(t.sport, .nfl)
        XCTAssertEqual(t.scale, "nfl_skill_ppr")
        XCTAssertEqual(t.positions, ["WR"])
        XCTAssertEqual(t.minStats, ["games": 10, "receiving_yards": 1000])
        XCTAssertEqual(t.poolCap, 24)
        XCTAssertEqual(t.grain, "season")
        XCTAssertEqual(t.columns.map(\.label), ["Rec Yds", "Rec", "Rec TD", "Yds/Rec", "Tgts"])
        XCTAssertEqual(t.columns.map(\.stat),
                       ["receiving_yards", "receptions", "receiving_tds", "ypr", "targets"])
        XCTAssertEqual(t.columns.map(\.fmt), ["comma_int", "int", "int", "dec1", "int"])
    }

    /// Every theme (any of the three grains — season/career/single-game are all
    /// creatable) must resolve to an app ScoringRule preset, so a template grades
    /// identically to the pipeline.
    func testAllGrainsResolveToPresetsAndAreCreatable() {
        for t in themes {
            XCTAssertNotNil(t.scoringRule, "\(t.key): scale \(t.scale) has no app preset")
            XCTAssertTrue(t.isCreatable, "\(t.key) should be creatable")
        }
        XCTAssertTrue(themes.contains { $0.grain == "career" }, "no career themes in bundle to assert against")
        XCTAssertTrue(themes.contains { $0.grain == "game" }, "no single-game themes in bundle to assert against")
    }

    /// Formatting parity with themes.py `_fmt_value` (locked values).
    func testFormatParity() {
        XCTAssertEqual(Keep4Theme.format(1848, fmt: "comma_int"), "1,848")
        XCTAssertEqual(Keep4Theme.format(1234567.4, fmt: "comma_int"), "1,234,567")
        XCTAssertEqual(Keep4Theme.format(999, fmt: "comma_int"), "999")
        XCTAssertEqual(Keep4Theme.format(17.0, fmt: "int"), "17")
        XCTAssertEqual(Keep4Theme.format(15.55, fmt: "dec1"), "15.6")
        XCTAssertEqual(Keep4Theme.format(0.612, fmt: "pct1"), "61.2")   // fraction → pct
        XCTAssertEqual(Keep4Theme.format(0.0, fmt: "comma_int"), "0")
    }

    /// A theme-built card must equal the daily pipeline's card for the same stats:
    /// mirrors assemble.py `_player_content` stats via themes.py `format_columns`.
    func testCardStatsMatchDailyShape() throws {
        let t = try XCTUnwrap(themes.first { $0.key == "nfl-wr-receiving" })
        // Calvin Johnson 2012-like line.
        let stats: [String: Double] = [
            "receiving_yards": 1964, "receptions": 122, "receiving_tds": 5,
            "ypr": 16.1, "targets": 204,
        ]
        let lines = t.cardStats(for: stats)
        XCTAssertEqual(lines, [
            .init(label: "Rec Yds", value: "1,964"),
            .init(label: "Rec", value: "122"),
            .init(label: "Rec TD", value: "5"),
            .init(label: "Yds/Rec", value: "16.1"),
            .init(label: "Tgts", value: "204"),
        ])
        // Missing stats render as formatted zero, same as Python's stats.get(col.stat, 0.0).
        XCTAssertEqual(t.cardStats(for: [:]).map(\.value), ["0", "0", "0", "0.0", "0"])
    }

    /// Cross-position column slicing parity with themes.py `columns_for`
    /// (locked by test_export_themes.py::test_cross_position_column_slicing).
    func testCrossPositionColumnSlicing() throws {
        let total = try XCTUnwrap(themes.first { $0.key == "nfl-total-fantasy" })
        XCTAssertEqual(total.columns(for: "WR").map(\.stat),
                       ["receptions", "receiving_yards", "receiving_tds"])
        XCTAssertEqual(total.columns(for: "QB").map(\.stat),
                       ["passing_yards", "passing_tds", "rushing_yards", "rushing_tds"])
        XCTAssertEqual(total.columns(for: "RB").map(\.stat),
                       ["rushing_yards", "rushing_tds", "receptions", "receiving_yards", "receiving_tds"])
        let wr = try XCTUnwrap(themes.first { $0.key == "nfl-wr-receiving" })
        XCTAssertEqual(wr.columns(for: "WR"), wr.columns)     // single-position: unchanged
        let nba = try XCTUnwrap(themes.first { $0.key == "nba-scorers" })
        XCTAssertEqual(nba.columns(for: "G"), nba.columns)    // NBA: unchanged
    }

    /// Grading a season through a theme's rule equals grade.py for that scale — the existing
    /// GradeFormula/ScoringRule locked tests carry the numeric parity; here we lock that the
    /// theme resolves to the same preset the pipeline names.
    func testThemeRuleGradesLikePipeline() throws {
        let t = try XCTUnwrap(themes.first { $0.key == "nfl-total-fantasy" })
        let rule = try XCTUnwrap(t.scoringRule)
        // 2019 Lamar Jackson-like line: 3127 pass yds, 36 pass TD, 6 INT, 1206 rush yds, 7 rush TD.
        let stats: [String: Double] = [
            "passing_yards": 3127, "passing_tds": 36, "interceptions": 6,
            "rushing_yards": 1206, "rushing_tds": 7,
        ]
        let g = rule.grade(stats: stats, sport: .nfl, position: "QB", seasonYear: 2019)
        // 3127*0.04 + 36*4 - 6*2 + 1206*0.1 + 7*6 = 125.08 + 144 - 12 + 120.6 + 42 = 419.7 (round .1)
        XCTAssertEqual(g, 419.7, accuracy: 0.001)
    }
}
