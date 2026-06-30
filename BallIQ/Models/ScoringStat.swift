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

    enum Fmt { case commaInt, int, dec1, pct }

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
    ]

    static func catalog(for sport: Sport) -> [ScoringStat] { catalog[sport] ?? [] }

    static func find(_ key: String, sport: Sport) -> ScoringStat? {
        catalog(for: sport).first { $0.key == key }
    }
}
