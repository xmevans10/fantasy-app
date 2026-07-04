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

    /// Themes the creation flow can offer: season or career grain (the catalog has no
    /// single-game rows — on-device grading isn't built for those) with a scale the app
    /// mirrors.
    var isCreatable: Bool { (grain == "season" || grain == "career") && scoringRule != nil }

    // MARK: - Card building (mirrors themes.py format_columns / _fmt_value exactly)

    /// Stat families an NFL position produces — mirrors themes.py `_NFL_POSITION_STATS` for
    /// per-position column selection on cross-position themes.
    private static let nflPositionStats: [String: [String]] = [
        "QB": ["passing_", "rushing_", "interceptions", "completions", "attempts", "completion_pct"],
        "RB": ["rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr"],
        "FB": ["rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr"],
        "WR": ["receiving_", "receptions", "targets", "ypr"],
        "TE": ["receiving_", "receptions", "targets", "ypr"],
    ]

    /// Card columns for a season at `position` — mirrors themes.py `columns_for`: cross-position
    /// NFL themes slice to the position's stat families (min 3, else full set).
    func columns(for position: String?) -> [Column] {
        guard let position, sport == .nfl, positions.count > 1,
              let prefixes = Self.nflPositionStats[position] else { return columns }
        let sliced = columns.filter { col in prefixes.contains { col.stat.hasPrefix($0) } }
        return sliced.count >= 3 ? sliced : columns
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

    /// Locale-independent thousands grouping (Python's f"{n:,}").
    private static func commaGrouped(_ n: Int) -> String {
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
