import Foundation

/// A stat a creator can rank by or display, with a friendly label, default reference bounds
/// (used as the fixed scale and as the era-adjust fallback), a default direction, and a display
/// format. This is the menu behind the composable scoring builder — it does not constrain who
/// can be added to a puzzle, only what axes exist to score and show.
struct ScoringStat: Identifiable, Hashable {
    let key: String                 // raw stat key, matches CatalogSeason.stats
    let label: String               // on-card / menu label, e.g. "Rec Yds"
    let sport: Sport
    let lo: Double
    let hi: Double
    let higherWins: Bool
    let fmt: Fmt

    var id: String { "\(sport.rawValue):\(key)" }

    enum Fmt { case commaInt, int, dec1, pct, dec3 }

    /// A fixed-scale scoring term seeded from this stat's defaults.
    func term(weight: Double = 1) -> ScoringRule.Term {
        ScoringRule.Term(stat: key, weight: weight, higherWins: higherWins,
                         norm: .fixed(.init(lo: lo, hi: hi)))
    }

    func format(_ value: Double) -> String {
        switch fmt {
        case .commaInt:
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
        case .int:  return "\(Int(value.rounded()))"
        case .dec1: return String(format: "%.1f", value)
        case .pct:  return "\(Int((value * 100).rounded()))%"
        case .dec3: return String(format: "%.3f", value)
        }
    }
}

extension ScoringStat {
    /// Selectable stats per sport (curated subset of the catalog's raw keys). Bounds for stats
    /// that also appear in `GradeFormula` presets match those scales for consistency.
    static let catalog: [Sport: [ScoringStat]] = [
        .nfl: [
            ScoringStat(key: "receiving_yards", label: "Rec Yds", sport: .nfl, lo: 850, hi: 1950, higherWins: true, fmt: .commaInt),
            ScoringStat(key: "receiving_tds",   label: "Rec TD",  sport: .nfl, lo: 3,   hi: 19,   higherWins: true, fmt: .int),
            ScoringStat(key: "receptions",      label: "Rec",     sport: .nfl, lo: 60,  hi: 145,  higherWins: true, fmt: .int),
            ScoringStat(key: "targets",         label: "Tgts",    sport: .nfl, lo: 60,  hi: 180,  higherWins: true, fmt: .int),
            ScoringStat(key: "ypr",             label: "Yds/Rec", sport: .nfl, lo: 8,   hi: 18,   higherWins: true, fmt: .dec1),
            ScoringStat(key: "rushing_yards",   label: "Rush Yds", sport: .nfl, lo: 850, hi: 2100, higherWins: true, fmt: .commaInt),
            ScoringStat(key: "rushing_tds",     label: "Rush TD", sport: .nfl, lo: 4,   hi: 28,   higherWins: true, fmt: .int),
            ScoringStat(key: "ypc",             label: "YPC",     sport: .nfl, lo: 3.5, hi: 6.2,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "carries",         label: "Carries", sport: .nfl, lo: 150, hi: 400,  higherWins: true, fmt: .int),
            ScoringStat(key: "passing_yards",   label: "Pass Yds", sport: .nfl, lo: 3000, hi: 5500, higherWins: true, fmt: .commaInt),
            ScoringStat(key: "passing_tds",     label: "Pass TD", sport: .nfl, lo: 18,  hi: 55,   higherWins: true, fmt: .int),
            ScoringStat(key: "interceptions",   label: "INT",     sport: .nfl, lo: 4,   hi: 24,   higherWins: false, fmt: .int),
            ScoringStat(key: "completion_pct",  label: "Cmp%",    sport: .nfl, lo: 55,  hi: 72,   higherWins: true, fmt: .dec1),
            ScoringStat(key: "completions",     label: "Cmp",     sport: .nfl, lo: 200, hi: 450,  higherWins: true, fmt: .int),
            ScoringStat(key: "attempts",        label: "Att",     sport: .nfl, lo: 300, hi: 700,  higherWins: true, fmt: .int),
        ],
        .nba: [
            ScoringStat(key: "ppg",    label: "PPG", sport: .nba, lo: 12.0,  hi: 37.0,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "rpg",    label: "RPG", sport: .nba, lo: 4.0,   hi: 15.0,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "apg",    label: "APG", sport: .nba, lo: 2.0,   hi: 14.5,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "spg",    label: "SPG", sport: .nba, lo: 0.5,   hi: 3.0,   higherWins: true, fmt: .dec1),
            ScoringStat(key: "bpg",    label: "BPG", sport: .nba, lo: 0.3,   hi: 3.7,   higherWins: true, fmt: .dec1),
            ScoringStat(key: "ts_pct", label: "TS%", sport: .nba, lo: 0.480, hi: 0.670, higherWins: true, fmt: .pct),
            ScoringStat(key: "fg_pct", label: "FG%", sport: .nba, lo: 0.420, hi: 0.620, higherWins: true, fmt: .pct),
            // Single-game raw totals (as opposed to the per-game rates above) — only
            // meaningful on `CatalogSeason.isGame` rows, see `Sport.positionStatTemplatesGame`.
            ScoringStat(key: "points",             label: "PTS", sport: .nba, lo: 10, hi: 60, higherWins: true, fmt: .int),
            ScoringStat(key: "rebounds",           label: "REB", sport: .nba, lo: 3,  hi: 25, higherWins: true, fmt: .int),
            ScoringStat(key: "assists",            label: "AST", sport: .nba, lo: 1,  hi: 20, higherWins: true, fmt: .int),
            ScoringStat(key: "steals",             label: "STL", sport: .nba, lo: 0,  hi: 8,  higherWins: true, fmt: .int),
            ScoringStat(key: "blocks",             label: "BLK", sport: .nba, lo: 0,  hi: 8,  higherWins: true, fmt: .int),
            ScoringStat(key: "field_goals_made",   label: "FGM", sport: .nba, lo: 2,  hi: 25, higherWins: true, fmt: .int),
        ],
        .baseball: [
            ScoringStat(key: "hits",           label: "Hits",     sport: .baseball, lo: 80,    hi: 200,   higherWins: true,  fmt: .int),
            ScoringStat(key: "doubles",        label: "2B",       sport: .baseball, lo: 15,    hi: 55,    higherWins: true,  fmt: .int),
            ScoringStat(key: "triples",        label: "3B",       sport: .baseball, lo: 0,     hi: 15,    higherWins: true,  fmt: .int),
            ScoringStat(key: "home_runs",      label: "HR",       sport: .baseball, lo: 5,     hi: 65,    higherWins: true,  fmt: .int),
            ScoringStat(key: "runs",           label: "R",        sport: .baseball, lo: 50,    hi: 140,   higherWins: true,  fmt: .int),
            ScoringStat(key: "rbi",            label: "RBI",      sport: .baseball, lo: 40,    hi: 140,   higherWins: true,  fmt: .int),
            ScoringStat(key: "base_on_balls",  label: "BB",       sport: .baseball, lo: 20,    hi: 120,   higherWins: true,  fmt: .int),
            ScoringStat(key: "stolen_bases",   label: "SB",       sport: .baseball, lo: 0,     hi: 70,    higherWins: true,  fmt: .int),
            ScoringStat(key: "avg",            label: "AVG",      sport: .baseball, lo: 0.230, hi: 0.340, higherWins: true,  fmt: .dec3),
            ScoringStat(key: "obp",            label: "OBP",      sport: .baseball, lo: 0.300, hi: 0.450, higherWins: true,  fmt: .dec3),
            ScoringStat(key: "slg",            label: "SLG",      sport: .baseball, lo: 0.380, hi: 0.700, higherWins: true,  fmt: .dec3),
            ScoringStat(key: "ops",            label: "OPS",      sport: .baseball, lo: 0.680, hi: 1.150, higherWins: true,  fmt: .dec3),
            ScoringStat(key: "innings_pitched", label: "IP",      sport: .baseball, lo: 80,    hi: 230,   higherWins: true,  fmt: .dec1),
            ScoringStat(key: "wins",           label: "W",        sport: .baseball, lo: 5,     hi: 24,    higherWins: true,  fmt: .int),
            ScoringStat(key: "saves",          label: "SV",       sport: .baseball, lo: 0,     hi: 60,    higherWins: true,  fmt: .int),
            ScoringStat(key: "strike_outs",    label: "K",        sport: .baseball, lo: 60,    hi: 320,   higherWins: true,  fmt: .int),
            ScoringStat(key: "earned_runs",    label: "ER",       sport: .baseball, lo: 20,    hi: 90,    higherWins: false, fmt: .int),
            ScoringStat(key: "era",            label: "ERA",      sport: .baseball, lo: 1.5,   hi: 5.5,   higherWins: false, fmt: .dec3),
            ScoringStat(key: "whip",           label: "WHIP",     sport: .baseball, lo: 0.80,  hi: 1.40,  higherWins: false, fmt: .dec3),
        ],
        .soccer: [
            ScoringStat(key: "appearances",  label: "Apps",         sport: .soccer, lo: 15, hi: 38, higherWins: true, fmt: .int),
            ScoringStat(key: "goals",        label: "Goals",        sport: .soccer, lo: 0,  hi: 40, higherWins: true, fmt: .int),
            ScoringStat(key: "assists",      label: "Assists",      sport: .soccer, lo: 0,  hi: 20, higherWins: true, fmt: .int),
            ScoringStat(key: "clean_sheets", label: "Clean Sheets", sport: .soccer, lo: 0,  hi: 25, higherWins: true, fmt: .int),
        ],
        .tennis: [
            ScoringStat(key: "matches_won",  label: "Wins",   sport: .tennis, lo: 20, hi: 100, higherWins: true,  fmt: .int),
            ScoringStat(key: "matches_lost", label: "Losses", sport: .tennis, lo: 0,  hi: 25,  higherWins: false, fmt: .int),
            ScoringStat(key: "titles",       label: "Titles", sport: .tennis, lo: 0,  hi: 15,  higherWins: true,  fmt: .int),
            ScoringStat(key: "grand_slams",  label: "Slams",  sport: .tennis, lo: 0,  hi: 4,   higherWins: true,  fmt: .int),
        ],
    ]

    static func catalog(for sport: Sport) -> [ScoringStat] { catalog[sport] ?? [] }

    static func find(_ key: String, sport: Sport) -> ScoringStat? {
        catalog(for: sport).first { $0.key == key }
    }

    /// The display stats for a season at `position` — free-form creation's answer to
    /// `Keep4Theme.columns(for:)`.
    ///
    /// When a scoring rule is active, its own terms (`preferredKeys`) constrain *which*
    /// stats can show — display should reflect what's actually being scored — but a unified
    /// cross-position formula like `nfl_fantasy` declares its terms in scoring-parity order
    /// (receiving before rushing, mirroring `grade.py`), not display prominence. Ordering by
    /// raw declaration order let a PPR-scored RB's card show "Rec/Rec Yds/Rec TD" ahead of
    /// its rushing line — the same bug this whole mechanism exists to prevent, just via the
    /// preset-scoring path instead of Vibes. So the scored terms are re-ordered by
    /// `Sport.positionStatTemplates` (this position's own obvious stat sheet) whenever one
    /// exists, keeping only the ones the active rule actually scores.
    static func displayColumns(sport: Sport, position: String?,
                              preferredKeys: [String] = [],
                              grain: PuzzleGrain = .season) -> [ScoringStat] {
        let all = catalog(for: sport)
        let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
        // minimum: 0 — trust the position filter even if it empties the preferred set out
        // entirely (e.g. an NFL-QB rule's terms against a WR card); falling back to the
        // *unfiltered* preferred keys here would resurrect the exact bug this exists to fix.
        let preferred = sport.sliceForPosition(
            preferredKeys.compactMap { byKey[$0] },
            position: position, minimum: 0, statKey: \.key)

        let templated = template(sport: sport, position: position, grain: grain)
        if !templated.isEmpty {
            guard !preferred.isEmpty else { return templated }
            let scoredKeys = Set(preferred.map(\.key))
            let ordered = templated.filter { scoredKeys.contains($0.key) }
            if ordered.count >= 3 { return Array(ordered.prefix(3)) }
            // The rule scores too few of this position's template stats to fill a card —
            // pad with whatever else it does score (already position-sliced).
            let combined = ordered + preferred.filter { !ordered.contains($0) }
            return combined.count >= 3 ? Array(combined.prefix(3)) : templated
        }

        if preferred.count >= 3 { return Array(preferred.prefix(3)) }

        // No template for this sport/position (NBA/tennis, or an unrecognized position) —
        // position-relevant stats first (however many exist), padded with the sport's
        // remaining stats in catalog order. Never falls back to the *unsliced* set outright:
        // that would let position-irrelevant stats back in ahead of ones that do apply.
        let relevant = sport.sliceForPosition(all, position: position, minimum: 0, statKey: \.key)
        let padding = all.filter { !relevant.contains($0) }
        return Array((relevant + padding).prefix(3))
    }

    /// `position`'s explicit default stat sheet, resolved to full `ScoringStat`s in template
    /// order — empty if the sport/position has no template. `grain == .singleGame` prefers
    /// `Sport.positionStatTemplatesGame`'s override (NBA/baseball, whose game-row stat keys
    /// differ from their season ones) and falls back to the season template `positionStatTemplates`
    /// when no override exists (NFL/soccer, whose game rows reuse the season key names).
    static func template(sport: Sport, position: String?, grain: PuzzleGrain = .season) -> [ScoringStat] {
        guard let position else { return [] }
        let keys: [String]
        if grain == .singleGame, let gameKeys = Sport.positionStatTemplatesGame[sport]?[position] {
            keys = gameKeys
        } else if let seasonKeys = Sport.positionStatTemplates[sport]?[position] {
            keys = seasonKeys
        } else {
            return []
        }
        let byKey = Dictionary(uniqueKeysWithValues: catalog(for: sport).map { ($0.key, $0) })
        return keys.compactMap { byKey[$0] }
    }
}
