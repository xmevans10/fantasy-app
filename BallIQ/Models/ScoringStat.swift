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
            ScoringStat(key: "rushing_yards",   label: "Rush Yds", sport: .nfl, lo: 850, hi: 2100, higherWins: true, fmt: .commaInt),
            ScoringStat(key: "rushing_tds",     label: "Rush TD", sport: .nfl, lo: 4,   hi: 28,   higherWins: true, fmt: .int),
            ScoringStat(key: "ypc",             label: "YPC",     sport: .nfl, lo: 3.5, hi: 6.2,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "carries",         label: "Carries", sport: .nfl, lo: 150, hi: 400,  higherWins: true, fmt: .int),
            ScoringStat(key: "passing_yards",   label: "Pass Yds", sport: .nfl, lo: 3000, hi: 5500, higherWins: true, fmt: .commaInt),
            ScoringStat(key: "passing_tds",     label: "Pass TD", sport: .nfl, lo: 18,  hi: 55,   higherWins: true, fmt: .int),
            ScoringStat(key: "interceptions",   label: "INT",     sport: .nfl, lo: 4,   hi: 24,   higherWins: false, fmt: .int),
            ScoringStat(key: "completion_pct",  label: "Cmp%",    sport: .nfl, lo: 55,  hi: 72,   higherWins: true, fmt: .dec1),
        ],
        .nba: [
            ScoringStat(key: "ppg",    label: "PPG", sport: .nba, lo: 12.0,  hi: 37.0,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "rpg",    label: "RPG", sport: .nba, lo: 4.0,   hi: 15.0,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "apg",    label: "APG", sport: .nba, lo: 2.0,   hi: 14.5,  higherWins: true, fmt: .dec1),
            ScoringStat(key: "spg",    label: "SPG", sport: .nba, lo: 0.5,   hi: 3.0,   higherWins: true, fmt: .dec1),
            ScoringStat(key: "bpg",    label: "BPG", sport: .nba, lo: 0.3,   hi: 3.7,   higherWins: true, fmt: .dec1),
            ScoringStat(key: "ts_pct", label: "TS%", sport: .nba, lo: 0.480, hi: 0.670, higherWins: true, fmt: .pct),
            ScoringStat(key: "fg_pct", label: "FG%", sport: .nba, lo: 0.420, hi: 0.620, higherWins: true, fmt: .pct),
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

    /// The best 3 display stats for a season at `position` — free-form creation's answer to
    /// `Keep4Theme.columns(for:)`, sharing the same `Sport.positionStatFamilies` table so a
    /// Vibes puzzle or a custom-rule pool never shows a card a stat family its position
    /// doesn't record (a QB's "Rec Yds", a pitcher's "AVG", a keeper's "Goals").
    ///
    /// `preferredKeys` (a scoring rule's own terms, when one is active) are tried first —
    /// display should reflect what's actually being scored — filtered to the position's
    /// families; only once that's under 3 does it fall back to the position's generic
    /// defaults, and finally to the sport's unfiltered top 3.
    static func displayColumns(sport: Sport, position: String?,
                              preferredKeys: [String] = []) -> [ScoringStat] {
        let all = catalog(for: sport)
        // minimum: 0 — trust the position filter even if it empties the preferred set out
        // entirely (e.g. an NFL-QB rule's terms against a WR card); falling back to the
        // *unfiltered* preferred keys here would resurrect the exact bug this exists to fix.
        let preferred = sport.sliceForPosition(
            preferredKeys.compactMap { key in all.first { $0.key == key } },
            position: position, minimum: 0, statKey: \.key)
        if preferred.count >= 3 { return Array(preferred.prefix(3)) }

        // Position-relevant stats first (however many exist — a soccer goalkeeper's family
        // is only 2 wide), padded with the sport's remaining stats in catalog order. Never
        // falls back to the *unsliced* set outright: that would let position-irrelevant
        // stats (a keeper's goals/assists) back in ahead of ones that do apply.
        let relevant = sport.sliceForPosition(all, position: position, minimum: 0, statKey: \.key)
        let padding = all.filter { !relevant.contains($0) }
        return Array((relevant + padding).prefix(3))
    }
}
