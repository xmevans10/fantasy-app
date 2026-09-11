import Foundation

/// A daily-pipeline theme template, decoded from the bundled `keep4_themes.json` that
/// `tools/ingest` exports from `themes.py` `KEEP4_THEMES` (M10 unification: ONE definition
/// of a puzzle template, consumed by both the pipeline and the creation flow).
///
/// Picking a theme in `CreateKeep4View` sets the scoring rule (`scale` → `ScoringRule.preset`),
/// the discovery position filters, and — crucially — the published card's stat columns, so a
/// community puzzle built from a theme is indistinguishable in shape from that theme's daily
/// rows. Parity with the Python export is locked by `Keep4ThemeTests` (Swift) and
/// `test_export_themes.py` (Python).
struct Keep4Theme: Codable, Equatable, Identifiable {

    struct Column: Codable, Equatable {
        let stat: String     // raw stat key (snake_case, matches CatalogSeason.stats)
        let label: String    // on-card label, e.g. "Rec Yds"
        let fmt: String      // 'comma_int' | 'int' | 'dec1' | 'pct1' | 'dec3' | 'dec2' (mirrors themes.py)
    }

    let key: String
    let title: String
    let sport: Sport
    let scale: String                  // grade scale key — resolves via ScoringRule.preset
    let positions: [String]
    let minStats: [String: Double]
    let columns: [Column]
    let poolCap: Int
    let grain: String                  // 'season' | 'game'
    /// Grade with era-adjusted fantasy points (raw total × era volume index) — the theme's
    /// rule should be applied via `scoringRule?.eraAdjusted(true)`.
    let eraAdjusted: Bool

    var id: String { key }

    /// The scoring rule this theme grades with — identical math to the pipeline's grade.py.
    var scoringRule: ScoringRule? { ScoringRule.preset(scale) }

    /// Themes the creation flow can offer: any of the three grains (season, career, or
    /// single-game — a puzzle is a puzzle regardless of grain) with a scale the app mirrors.
    var isCreatable: Bool { PuzzleGrain(rawValue: grain) != nil && scoringRule != nil }

    // MARK: - Card building (mirrors themes.py format_columns / _fmt_value exactly)

    /// The card layout is built for four or five tiles (`Keep4CardView.statRows` balances
    /// 5 → 3+2 and 4 → 2+2); past that the numbers shrink and the sheet reads as a table.
    static let maxCardColumns = 5

    /// Card columns for a season at `position` — mirrors themes.py `columns_for`.
    ///
    /// A single-position theme, and any position that produces every stat the theme names,
    /// keeps the theme's own curated columns: those were chosen for one stat vocabulary, and
    /// a hockey board mixing C/L/R is only nominally cross-position (the three skater codes
    /// record the same things), so "Modern snipers" showing G/SOG/S%/PTS is that theme's
    /// emphasis, not a defect.
    ///
    /// Otherwise the theme names a stat this position cannot produce, and the card is built
    /// from the position's canonical stat card (`Sport.positionStatTemplates`) instead: each
    /// canonical key rendered with the theme's own column where it declares one (keeping that
    /// theme's label and grain-correct format) and `fillColumns` where it doesn't, then any
    /// other theme column the position does produce. The whole thing is capped at
    /// `maxCardColumns`, which the canonical card takes first — so a position whose canonical
    /// card is already that long (NFL QB) has no room for that tail. Right precedence, since
    /// the canonical line is what a player reads the card by, but it does mean a theme's
    /// promoted column can be crowded out on those positions.
    ///
    /// There is deliberately no fall-back-to-everything branch. The old slice had one, for
    /// when filtering left too few columns — and it is what put "Pass Yds 0 · Pass TD 0 ·
    /// Rush TD 0" on a Travis Kelce card in the 2026-09-06 daily. Composing from the
    /// canonical card cannot run out of honest columns, so nothing needs to fall back.
    func columns(for position: String?) -> [Column] {
        guard positions.count > 1, let position else { return columns }
        if columns.allSatisfy({ sport.produces(position: position, stat: $0.stat) }) { return columns }
        let canonical = sport.canonicalCard(position: position,
                                            grain: PuzzleGrain(rawValue: grain) ?? .season)
        guard !canonical.isEmpty else { return columns }
        let declared = Dictionary(columns.map { ($0.stat, $0) }, uniquingKeysWith: { first, _ in first })
        let fill = Keep4Theme.fillColumns[sport] ?? [:]
        var out = canonical.compactMap { declared[$0] ?? fill[$0] }
        let seen = Set(out.map(\.stat))
        out += columns.filter { !seen.contains($0.stat) && sport.produces(position: position, stat: $0.stat) }
        return out.isEmpty ? columns : Array(out.prefix(Keep4Theme.maxCardColumns))
    }

    /// Label and format for a canonical-card stat the theme itself doesn't declare — needed
    /// only for FILLED-IN columns, since a stat the theme names keeps that theme's own
    /// label/fmt. A byte-parity mirror of themes.py's `_FILL_COLUMNS` (locked by
    /// `Keep4ThemeTests`), NOT derived from `ScoringStat.catalog`: that catalog is the
    /// *scoring* menu and formats several of these differently on purpose (its `.pct` renders
    /// "61%" where a card's `pct1` renders "61.2", and its ERA/AVG bounds use `dec3`).
    /// `comma_int` wherever a career total can pass four digits — it renders identically to
    /// `int` below 1,000, so season cards are unaffected.
    static let fillColumns: [Sport: [String: Column]] = [
        .nfl: byStat([
            Column(stat: "passing_yards", label: "Pass Yds", fmt: "comma_int"),
            Column(stat: "passing_tds", label: "Pass TD", fmt: "int"),
            Column(stat: "interceptions", label: "INT", fmt: "int"),
            Column(stat: "rushing_yards", label: "Rush Yds", fmt: "comma_int"),
            Column(stat: "rushing_tds", label: "Rush TD", fmt: "int"),
            Column(stat: "receiving_yards", label: "Rec Yds", fmt: "comma_int"),
            Column(stat: "receiving_tds", label: "Rec TD", fmt: "int"),
            Column(stat: "receptions", label: "Rec", fmt: "comma_int"),
            Column(stat: "completions", label: "Cmp", fmt: "comma_int"),
            Column(stat: "attempts", label: "Att", fmt: "comma_int"),
            Column(stat: "completion_pct", label: "Cmp%", fmt: "dec1"),
            Column(stat: "ypc", label: "Yds/Carry", fmt: "dec1"),
            // Defensive keys match nfl_nflverse_defense.py's vocabulary — `def_interceptions`,
            // never `interceptions`, which on an offensive row means "thrown by a QB".
            Column(stat: "sacks", label: "Sacks", fmt: "int"),
            Column(stat: "tackles_combined", label: "Tackles", fmt: "comma_int"),
            Column(stat: "tackles_for_loss", label: "TFL", fmt: "int"),
            Column(stat: "qb_hits", label: "QB Hits", fmt: "int"),
            Column(stat: "def_interceptions", label: "Def INT", fmt: "int"),
            Column(stat: "passes_defended", label: "PD", fmt: "int"),
            Column(stat: "forced_fumbles", label: "FF", fmt: "int"),
        ]),
        .hockey: byStat([
            Column(stat: "goals", label: "G", fmt: "int"),
            Column(stat: "assists", label: "A", fmt: "int"),
            Column(stat: "points", label: "PTS", fmt: "int"),
            Column(stat: "plus_minus", label: "+/-", fmt: "int"),
            Column(stat: "wins", label: "W", fmt: "int"),
            Column(stat: "gaa", label: "GAA", fmt: "dec2"),
            Column(stat: "save_pct", label: "SV%", fmt: "dec3"),
            Column(stat: "shutouts", label: "SO", fmt: "int"),
        ]),
        .baseball: byStat([
            Column(stat: "home_runs", label: "HR", fmt: "comma_int"),
            Column(stat: "rbi", label: "RBI", fmt: "comma_int"),
            Column(stat: "avg", label: "AVG", fmt: "dec3"),
            Column(stat: "hits", label: "Hits", fmt: "comma_int"),
            Column(stat: "wins", label: "W", fmt: "int"),
            Column(stat: "era", label: "ERA", fmt: "dec2"),
            Column(stat: "strike_outs", label: "K", fmt: "comma_int"),
            Column(stat: "earned_runs", label: "ER", fmt: "int"),
            Column(stat: "innings_pitched", label: "IP", fmt: "dec1"),
        ]),
        .soccer: byStat([
            Column(stat: "goals", label: "Goals", fmt: "int"),
            Column(stat: "assists", label: "Assists", fmt: "int"),
            Column(stat: "appearances", label: "Apps", fmt: "int"),
            Column(stat: "clean_sheets", label: "Clean Sheets", fmt: "int"),
        ]),
    ]

    private static func byStat(_ columns: [Column]) -> [String: Column] {
        Dictionary(columns.map { ($0.stat, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The card `stats` array for a season's raw stats — same labels, order, and formatting
    /// as the daily pipeline's `format_columns`, so theme-built community cards match.
    func cardStats(for stats: [String: Double], position: String? = nil) -> [PlayerSeason.StatLine] {
        columns(for: position).map { col in
            .init(label: col.label, value: Self.format(stats[col.stat] ?? 0, fmt: col.fmt))
        }
    }

    /// Byte-parity port of themes.py `_fmt_value`.
    static func format(_ value: Double, fmt: String) -> String {
        switch fmt {
        case "comma_int": return commaGrouped(Int(value.rounded()))
        case "int":       return "\(Int(value.rounded()))"
        case "dec1":      return String(format: "%.1f", value)
        case "pct1":      return String(format: "%.1f", value * 100)   // 0.612 → "61.2"
        case "dec3":      return String(format: "%.3f", value)   // rate stats needing 3 places (baseball AVG/OPS)
        case "dec2":      return String(format: "%.2f", value)   // rate stats conventionally 2 places (ERA/WHIP)
        default:          return "\(value)"
        }
    }

    /// Locale-independent thousands grouping (Python's f"{n:,}"). Internal — also the
    /// grouping behind `PlayerSeason.gradeText`, so cards and grades format identically.
    static func commaGrouped(_ n: Int) -> String {
        let sign = n < 0 ? "-" : ""
        let digits = Array(String(n.magnitude))
        var out: [Character] = []
        for (i, d) in digits.enumerated() {
            let remaining = digits.count - i
            if i > 0 && remaining % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return sign + String(out)
    }

    // MARK: - Loading

    /// The bundled themes, loaded once — hot paths (per-card scoring-kind resolution) shouldn't
    /// re-read the resource.
    static let bundled: [Keep4Theme] = loadBundled()

    /// All themes from the bundled export (empty if the resource is missing).
    static func loadBundled() -> [Keep4Theme] {
        guard let url = Bundle.main.url(forResource: "keep4_themes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Keep4Theme].self, from: data)) ?? []
    }
}
