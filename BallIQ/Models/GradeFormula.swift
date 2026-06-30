import Foundation

/// Client port of the M3 ingestion grade formula (`tools/ingest/grade.py`).
///
/// User-generated Keep4 puzzles pick real player-seasons from the catalog; the
/// four highest grades are the correct "Keep" pile. We compute the grade on the
/// creator's device so the live preview shows the true ranking, then bake it into
/// the puzzle `content` — identical to how the pipeline bakes grades for dailies.
///
/// The reference scales below are copied verbatim from `grade.py`; `GradeFormulaTests`
/// locks the two implementations to the same orderings.
enum GradeFormula {

    /// (statKey, lo, hi, weight, invert) — invert means lower raw value scores higher.
    private struct Component {
        let key: String, lo: Double, hi: Double, weight: Double, invert: Bool
    }

    private static let scales: [String: [Component]] = [
        "nfl_wr": [
            Component(key: "receiving_yards", lo: 850, hi: 1950, weight: 0.60, invert: false),
            Component(key: "receiving_tds",   lo: 3,   hi: 19,   weight: 0.25, invert: false),
            Component(key: "receptions",      lo: 60,  hi: 145,  weight: 0.15, invert: false),
        ],
        "nfl_rb": [
            Component(key: "rushing_yards", lo: 850, hi: 2100, weight: 0.60, invert: false),
            Component(key: "rushing_tds",   lo: 4,   hi: 28,   weight: 0.25, invert: false),
            Component(key: "ypc",           lo: 3.5, hi: 6.2,  weight: 0.15, invert: false),
        ],
        "nfl_qb": [
            Component(key: "passing_yards", lo: 3000, hi: 5500, weight: 0.42, invert: false),
            Component(key: "passing_tds",   lo: 18,   hi: 55,   weight: 0.40, invert: false),
            Component(key: "interceptions", lo: 4,    hi: 24,   weight: 0.18, invert: true),
        ],
        "nba_scorer": [
            Component(key: "ppg",    lo: 20.0,  hi: 37.0,  weight: 0.68, invert: false),
            Component(key: "ts_pct", lo: 0.500, hi: 0.670, weight: 0.20, invert: false),
            Component(key: "apg",    lo: 2.0,   hi: 11.0,  weight: 0.12, invert: false),
        ],
        "nba_big": [
            Component(key: "ppg", lo: 16.0, hi: 30.0, weight: 0.45, invert: false),
            Component(key: "rpg", lo: 8.0,  hi: 15.0, weight: 0.35, invert: false),
            Component(key: "bpg", lo: 0.8,  hi: 3.7,  weight: 0.20, invert: false),
        ],
        "nba_playmaker": [
            Component(key: "apg",    lo: 6.0,   hi: 14.5,  weight: 0.55, invert: false),
            Component(key: "ppg",    lo: 12.0,  hi: 34.0,  weight: 0.30, invert: false),
            Component(key: "ts_pct", lo: 0.480, hi: 0.660, weight: 0.15, invert: false),
        ],
    ]

    /// Fantasy-point scales (mirror grade.py `_FANTASY`): (statKey, perUnit). The raw total
    /// (`Σ value × perUnit`) is then min-maxed into 0–100 via `fantasyBounds` — a strict
    /// monotonic transform, so ranking is unchanged from raw points; only the displayed number
    /// reads on the same familiar scale as every other formula. A penalty's sign lives in its
    /// coefficient (interceptions at −2).
    private static let fantasy: [String: [(String, Double)]] = [
        "nfl_skill_ppr": [("receptions", 1.0), ("receiving_yards", 0.1), ("receiving_tds", 6.0),
                          ("rushing_yards", 0.1), ("rushing_tds", 6.0)],
        "nfl_qb_fantasy": [("passing_yards", 0.04), ("passing_tds", 4.0), ("interceptions", -2.0),
                           ("rushing_yards", 0.1), ("rushing_tds", 6.0)],
        "nba_fantasy": [("ppg", 1.0), ("rpg", 1.2), ("apg", 1.5), ("spg", 3.0), ("bpg", 3.0)],
    ]

    /// Display bounds (lo, hi) per fantasy scale — mirrors grade.py `_FANTASY_BOUNDS` exactly.
    /// See grade.py's docstring for how these were anchored to real catalog percentiles.
    private static let fantasyBounds: [String: (lo: Double, hi: Double)] = [
        "nfl_skill_ppr": (40.0, 450.0),
        "nfl_qb_fantasy": (100.0, 450.0),
        "nba_fantasy": (15.0, 75.0),
    ]

    private static func component(_ value: Double, _ c: Component) -> Double {
        let frac = c.invert ? (c.hi - value) / (c.hi - c.lo) : (value - c.lo) / (c.hi - c.lo)
        return 100.0 * min(1.0, max(0.0, frac))
    }

    /// Map a player-season's raw `stats` to a 0–100 quality score for the given scale (fixed or
    /// fantasy-points — both now read on the same scale).
    static func grade(_ stats: [String: Double], scale: String) -> Double {
        if let terms = fantasy[scale], let bounds = fantasyBounds[scale] {
            let raw = terms.reduce(0.0) { sum, t in sum + (stats[t.0] ?? 0) * t.1 }
            let frac = min(1.0, max(0.0, (raw - bounds.lo) / (bounds.hi - bounds.lo)))
            return (100.0 * frac * 10).rounded() / 10   // 1-decimal, matches Python round(x, 1)
        }
        guard let components = scales[scale] else { return 0 }
        let total = components.reduce(0.0) { sum, c in
            sum + c.weight * component(stats[c.key] ?? 0, c)
        }
        return (total * 10).rounded() / 10   // 1-decimal, matches Python round(x, 1)
    }
}

/// A real player-season from the catalog (`player_seasons` table). Carries raw numeric
/// stats so the grade can be computed for any creation template.
struct CatalogSeason: Identifiable, Codable, Equatable {
    let id: String
    let sport: Sport
    let name: String
    let teamAbbr: String
    let seasonYear: Int
    let position: String
    let stats: [String: Double]

    var subtitle: String { "\(teamAbbr) · \(seasonYear)" }

    // Explicit keys so this decodes with a PLAIN JSONDecoder — `stats` dict keys
    // (e.g. "rushing_yards") must stay snake_case for GradeFormula, so we must not
    // use the shared `.convertFromSnakeCase` decoder here.
    enum CodingKeys: String, CodingKey {
        case id, sport, name, position, stats
        case teamAbbr = "team_abbr"
        case seasonYear = "season_year"
    }
}

/// A Keep4 creation "sort dimension" — mirrors a `tools/ingest/themes.py` theme:
/// which grade scale judges the pool and which stats show on the card.
struct CreationTemplate: Identifiable, Hashable {
    let id: String            // grade scale key, e.g. "nfl_rb"
    let title: String         // e.g. "RB rushing"
    let sport: Sport
    let positions: [String]   // catalog filter
    let columns: [StatColumn]

    struct StatColumn: Hashable {
        let stat: String      // raw stat key
        let label: String     // on-card label
        let fmt: Fmt
        enum Fmt { case commaInt, int, dec1 }
    }

    var scale: String { id }

    /// Build the display `stats` array (camelCase StatLine) for a card.
    func statLines(for season: CatalogSeason) -> [PlayerSeason.StatLine] {
        columns.map { col in
            PlayerSeason.StatLine(label: col.label,
                                  value: Self.format(season.stats[col.stat] ?? 0, col.fmt))
        }
    }

    /// Turn a chosen catalog season into a graded `PlayerSeason` for the puzzle.
    func playerSeason(for season: CatalogSeason) -> PlayerSeason {
        PlayerSeason(id: season.id, name: season.name, teamAbbr: season.teamAbbr,
                     seasonYear: season.seasonYear, stats: statLines(for: season),
                     grade: GradeFormula.grade(season.stats, scale: scale))
    }

    private static func format(_ value: Double, _ fmt: StatColumn.Fmt) -> String {
        switch fmt {
        case .commaInt:
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
        case .int:  return "\(Int(value.rounded()))"
        case .dec1: return String(format: "%.1f", value)
        }
    }
}

extension CreationTemplate {
    /// The catalog of creation templates (one per grade scale). Mirrors `KEEP4_THEMES`.
    static let all: [CreationTemplate] = [
        CreationTemplate(id: "nfl_wr", title: "WR receiving", sport: .nfl, positions: ["WR"],
            columns: [.init(stat: "receiving_yards", label: "Rec Yds", fmt: .commaInt),
                      .init(stat: "receiving_tds", label: "TD", fmt: .int),
                      .init(stat: "receptions", label: "Rec", fmt: .int)]),
        CreationTemplate(id: "nfl_rb", title: "RB rushing", sport: .nfl, positions: ["RB"],
            columns: [.init(stat: "rushing_yards", label: "Rush Yds", fmt: .commaInt),
                      .init(stat: "rushing_tds", label: "TD", fmt: .int),
                      .init(stat: "ypc", label: "YPC", fmt: .dec1)]),
        CreationTemplate(id: "nfl_qb", title: "QB passing", sport: .nfl, positions: ["QB"],
            columns: [.init(stat: "passing_yards", label: "Yds", fmt: .commaInt),
                      .init(stat: "passing_tds", label: "TD", fmt: .int),
                      .init(stat: "interceptions", label: "INT", fmt: .int)]),
        CreationTemplate(id: "nba_scorer", title: "NBA scoring", sport: .nba, positions: ["G", "F", "C"],
            columns: [.init(stat: "ppg", label: "PPG", fmt: .dec1),
                      .init(stat: "rpg", label: "RPG", fmt: .dec1),
                      .init(stat: "apg", label: "APG", fmt: .dec1)]),
        CreationTemplate(id: "nba_big", title: "NBA bigs", sport: .nba, positions: ["F", "C"],
            columns: [.init(stat: "ppg", label: "PPG", fmt: .dec1),
                      .init(stat: "rpg", label: "RPG", fmt: .dec1),
                      .init(stat: "bpg", label: "BPG", fmt: .dec1)]),
        CreationTemplate(id: "nba_playmaker", title: "NBA playmakers", sport: .nba, positions: ["G", "F", "C"],
            columns: [.init(stat: "ppg", label: "PPG", fmt: .dec1),
                      .init(stat: "apg", label: "APG", fmt: .dec1),
                      .init(stat: "spg", label: "SPG", fmt: .dec1)]),
    ]
}
