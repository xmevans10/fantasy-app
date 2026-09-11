import XCTest
@testable import BallIQ

/// M10 template-unification parity: the Swift-decoded theme catalog must match
/// `tools/ingest/themes.py` `KEEP4_THEMES` (locked on the Python side by
/// `test_export_themes.py` against the same bundled `keep4_themes.json`).
final class Keep4ThemeTests: XCTestCase {

    private let themes = Keep4Theme.loadBundled()

    func testBundleDecodesAllThemes() {
        XCTAssertEqual(themes.count, 51, "bundled keep4_themes.json out of sync with themes.py")
        XCTAssertEqual(Set(themes.map(\.key)).count, themes.count, "duplicate theme keys")
    }

    func testEraThemeDecodesWithFlag() throws {
        let era = try XCTUnwrap(themes.first { $0.key == "nfl-total-fantasy-era" })
        XCTAssertTrue(era.eraAdjusted)
        XCTAssertTrue(era.isCreatable)
        XCTAssertEqual(era.scale, "nfl_fantasy")
        // Era-adjustment is deliberately rare — every other theme grades on raw points — so
        // assert the exact SET rather than a count. A bare count told you something had
        // changed but not what, and it silently encoded "NFL is the only sport that can do
        // this", which stopped being true when M31 made `baselines.TOTAL_SCALE` role-aware and
        // hockey became era-adjustable. Adding a key here should be a deliberate act.
        XCTAssertEqual(Set(themes.filter(\.eraAdjusted).map(\.key)),
                       ["nfl-total-fantasy-era", "hockey-scoring-forwards-era"])
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

    /// Cross-position card composition parity with themes.py `columns_for`
    /// (locked by test_export_themes.py::test_cross_position_card_composition).
    func testCrossPositionCardComposition() throws {
        let total = try XCTUnwrap(themes.first { $0.key == "nfl-total-fantasy" })
        XCTAssertEqual(total.columns(for: "WR").map(\.stat),
                       ["receiving_yards", "receptions", "receiving_tds"])
        XCTAssertEqual(total.columns(for: "TE").map(\.stat),
                       ["receiving_yards", "receptions", "receiving_tds"])
        // INT is a scored term of `nfl_fantasy` (-2/pick) that the theme's columns omit; the
        // canonical QB card puts it back, so the number can be reasoned about on the card.
        XCTAssertEqual(total.columns(for: "QB").map(\.stat),
                       ["passing_yards", "passing_tds", "interceptions", "rushing_yards", "rushing_tds"])
        XCTAssertEqual(total.columns(for: "RB").map(\.stat),
                       ["rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds", "receptions"])

        let wr = try XCTUnwrap(themes.first { $0.key == "nfl-wr-receiving" })
        XCTAssertEqual(wr.columns(for: "WR"), wr.columns)     // single-position: unchanged
        let nba = try XCTUnwrap(themes.first { $0.key == "nba-scorers" })
        XCTAssertEqual(nba.columns(for: "G"), nba.columns)    // NBA: no position split
        // C/L/R record the same things, so a skater theme keeps its own emphasis rather than
        // being rewritten to canonical G-A-P.
        let snipers = try XCTUnwrap(themes.first { $0.key == "hockey-modern-snipers" })
        XCTAssertEqual(snipers.columns(for: "C"), snipers.columns)
    }

    /// A keeper in a DF/GK theme gets the two keeper numbers, not "Goals 0 · Assists 0".
    /// Soccer's whole vocabulary is four keys, so this card is honestly two tiles wide.
    func testKeeperCardDropsOutfieldStats() throws {
        let backs = try XCTUnwrap(themes.first { $0.key == "soccer-defenders" })
        XCTAssertEqual(backs.columns(for: "GK").map(\.stat), ["clean_sheets", "appearances"])
        XCTAssertEqual(backs.columns(for: "DF"), backs.columns)   // a DF produces all four
    }

    /// The guarantee itself, over every bundled theme: no card column names a stat the
    /// position never records. Python's `test_no_theme_can_show_a_stat_its_position_never_records`
    /// covers the generated themes too (they aren't exported to the bundle).
    func testNoThemeShowsAStatItsPositionNeverRecords() {
        var offenders: [String] = []
        for theme in themes where theme.positions.count > 1 {
            for position in theme.positions {
                for column in theme.columns(for: position)
                where !theme.sport.produces(position: position, stat: column.stat) {
                    offenders.append("\(theme.key)/\(position): \(column.label)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "card columns a position never records")
    }

    /// `columns(for:)` can only fill a canonical key it has a label/format for — a key in
    /// `Sport.positionStatTemplates` missing from `fillColumns` would silently shorten a card.
    /// Mirrors test_export_themes.py::test_every_canonical_card_key_can_be_rendered.
    func testEveryCanonicalCardKeyCanBeRendered() {
        for (sport, byPosition) in Sport.positionStatTemplates.merging(
            Sport.positionStatTemplatesGame, uniquingKeysWith: { season, game in
                season.merging(game, uniquingKeysWith: { _, g in g })
            }) {
            // NBA has game templates but no card fill table — `columns(for:)` returns the
            // theme's own columns there (no position split), so nothing is ever filled.
            guard let fill = Keep4Theme.fillColumns[sport] else { continue }
            for (position, keys) in byPosition {
                let missing = keys.filter { fill[$0] == nil }
                XCTAssertEqual(missing, [], "\(sport.rawValue)/\(position) unrenderable keys")
            }
        }
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
