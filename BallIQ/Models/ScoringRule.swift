import Foundation

/// A composable scoring axis for Keep4/Cut4 creation. Generalizes the six hardcoded
/// `GradeFormula` scales into an editable list of weighted stat terms, each with a
/// direction (higher- vs lower-wins) and a normalization:
///
/// - `.fixed(lo, hi)` — linear clamp against documented reference bounds (today's behavior).
/// - `.eraAdjusted` — z-score the stat against its (sport, stat, season-year) distribution
///   so 1,400 receiving yards in 2004 and 2024 are judged relative to their era. Falls back
///   to a fixed scale when no baseline exists or the season's sample is too thin.
/// - `.points(perUnit)` — fantasy-point contribution (`value * perUnit`), summed with no
///   weight-normalization. The grade *is* the raw fantasy total (so the audited PPR fix holds
///   and the displayed number is the season's real point total — see the "PPR scoring" note in
///   `CreateKeep4View`). Points rules are homogeneous (all terms `.points`); a penalty's sign
///   lives in its coefficient (e.g. interceptions at −2), so `higherWins` is ignored. A custom
///   rule can still opt into the legacy 0–100 normalized display by setting `displayScale`.
/// - `.eraPoints(perUnit)` — era-adjusted fantasy points. The rule's raw fantasy TOTAL is scaled
///   by a single per-(sport, position, season-year) *volume index* (see `eraTotalIndex`), so the
///   same production is worth more in a scarce era. A single total index — validated by
///   tools/ingest/era_analysis.py (M10) — is a monotonic rescale within a position-year, so it
///   can never reorder two same-position same-year seasons the way noisy per-stat ratios can.
///   Falls back to `.points` (index 1.0) when no trustworthy baseline exists. Toggling
///   `eraAdjusted` swaps `.points` ↔ `.eraPoints`. Mirrored by grade.py `era_index`/`grade_era`.
///
/// The six built-in fixed presets reproduce the `GradeFormula` scales *exactly* (same stats,
/// bounds, weights, inversions); the fantasy presets mirror grade.py's `_FANTASY` byte-for-byte.
/// Either way `GradeFormulaTests` parity with `tools/ingest/grade.py` is preserved.
struct ScoringRule: Equatable, Hashable {

    struct FixedScale: Equatable, Hashable {
        let lo: Double
        let hi: Double
    }

    enum Normalization: Equatable, Hashable {
        case fixed(FixedScale)
        case eraAdjusted(fallback: FixedScale)
        case points(perUnit: Double)
        case eraPoints(perUnit: Double)
    }

    struct Term: Equatable, Hashable {
        let stat: String          // raw stat key, e.g. "rushing_yards"
        let weight: Double        // relative weight; the composite normalizes by the sum
        let higherWins: Bool      // false → lower raw value scores higher (e.g. interceptions)
        let norm: Normalization
    }

    let terms: [Term]
    /// Legacy 0–100 display bounds for a points rule's raw fantasy total. The shipped
    /// presets leave this nil — the grade IS the raw point total, shown as-is (see
    /// `CreateKeep4View`'s "PPR scoring" note) — but a custom rule can still opt into the
    /// old normalized display by setting one.
    let displayScale: FixedScale?

    init(terms: [Term], displayScale: FixedScale? = nil) {
        self.terms = terms
        self.displayScale = displayScale
    }

    /// Minimum season-sample size for an era baseline to be trusted; below this we fall back.
    static let minBaselineSamples = 8

    // MARK: - Grading

    /// True for a fantasy-points rule (any `.points`/`.eraPoints` term). Such rules grade by
    /// point total, bypassing the 0–100 weight-normalized path.
    var isPoints: Bool {
        terms.contains {
            switch $0.norm { case .points, .eraPoints: return true; default: return false }
        }
    }

    /// Quality score for a player-season. For points rules this is the fantasy total
    /// (`Σ value × perUnit`, no normalization; `.eraPoints` scales value by the era volume index
    /// first); otherwise a 0–100 weight-normalized score so arbitrary custom weights work
    /// (presets sum to 1.0, a no-op for parity). `position` selects the baseline population.
    func grade(stats: [String: Double], sport: Sport, position: String, seasonYear: Int,
               baselines: StatBaselines? = nil) -> Double {
        if isPoints {
            // Points rules sum contributions directly — no weight-normalize.
            var raw = terms.reduce(0.0) { sum, term in
                switch term.norm {
                case .points(let perUnit), .eraPoints(let perUnit):
                    return sum + (stats[term.stat] ?? 0) * perUnit
                default:
                    return sum   // fixed/era terms don't participate in a points rule
                }
            }
            let isEra = terms.contains { if case .eraPoints = $0.norm { return true } else { return false } }
            if isEra {
                raw *= Self.eraTotalIndex(sport: sport, position: position,
                                          year: seasonYear, baselines: baselines)
            }
            guard let scale = displayScale else {
                return (raw * 10).rounded() / 10   // no display bounds configured — show raw points
            }
            let frac = Self.clamp((raw - scale.lo) / (scale.hi - scale.lo))
            return (100 * frac * 10).rounded() / 10   // 1-decimal, matches Python round(x, 1)
        }
        let weightSum = terms.reduce(0) { $0 + $1.weight }
        guard weightSum > 0 else { return 0 }
        let total = terms.reduce(0.0) { sum, term in
            sum + term.weight * component(stats[term.stat] ?? 0, term, sport: sport,
                                          position: position, seasonYear: seasonYear,
                                          baselines: baselines)
        }
        return ((total / weightSum) * 10).rounded() / 10   // 1-decimal, matches Python round(x, 1)
    }

    /// Convenience: grade a catalog season directly.
    func grade(_ season: CatalogSeason, baselines: StatBaselines? = nil) -> Double {
        grade(stats: season.stats, sport: season.sport, position: season.position,
              seasonYear: season.seasonYear, baselines: baselines)
    }

    private func component(_ value: Double, _ term: Term, sport: Sport, position: String,
                           seasonYear: Int, baselines: StatBaselines?) -> Double {
        switch term.norm {
        case .fixed(let scale):
            return Self.fixedComponent(value, scale, higherWins: term.higherWins)
        case .eraAdjusted(let fallback):
            if let b = baselines?.lookup(sport: sport, position: position, stat: term.stat, year: seasonYear),
               b.count >= Self.minBaselineSamples, b.std > 0 {
                var z = (value - b.mean) / b.std
                if !term.higherWins { z = -z }
                // Map z ∈ [-2, +2] → [0, 100]; ±2σ ≈ the fringe/all-time-great band.
                return 100 * Self.clamp((z + 2) / 4)
            }
            return Self.fixedComponent(value, fallback, higherWins: term.higherWins)
        case .points(let perUnit), .eraPoints(let perUnit):
            // Unreachable via grade() (points rules take the isPoints path); kept for
            // exhaustiveness and any direct component() use.
            return value * perUnit
        }
    }

    /// The pseudo-stat baselines.py emits: the unified fantasy-total distribution over
    /// QUALIFY-gated (full-time) seasons per (sport, position, year).
    static let fantasyTotalStat = "fantasy_total"

    /// The single per-(sport, position, year) fantasy-total volume index (>1 = scarcer era):
    ///
    ///     globalMean(fantasy_total) / eraMean(fantasy_total, year)
    ///
    /// over the `fantasy_total` pseudo-stat rows (qualified-season populations — raw recorder
    /// means are diluted by cameo seasons and population growth). Returns 1.0 when the era row
    /// is missing/too thin or a mean is non-positive. Byte-parity with grade.py `era_index`.
    static func eraTotalIndex(sport: Sport, position: String, year: Int,
                              baselines: StatBaselines?) -> Double {
        guard let baselines,
              let era = baselines.lookup(sport: sport, position: position,
                                         stat: fantasyTotalStat, year: year),
              era.count >= minBaselineSamples, era.mean > 0,
              let global = baselines.globalMean(sport: sport, position: position,
                                                stat: fantasyTotalStat),
              global > 0
        else { return 1.0 }
        return global / era.mean
    }

    static func fixedComponent(_ value: Double, _ scale: FixedScale, higherWins: Bool) -> Double {
        let frac = higherWins
            ? (value - scale.lo) / (scale.hi - scale.lo)
            : (scale.hi - value) / (scale.hi - scale.lo)
        return 100 * clamp(frac)
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

// MARK: - Presets (mirror GradeFormula scales / grade.py exactly)

extension ScoringRule {
    /// Built-in scoring presets keyed by the legacy grade-scale id. Each is bit-for-bit
    /// equivalent to the corresponding `GradeFormula` scale.
    static let presets: [String: ScoringRule] = [
        "nfl_wr": rule(("receiving_yards", 850, 1950, 0.60, true),
                       ("receiving_tds",     3,   19, 0.25, true),
                       ("receptions",       60,  145, 0.15, true)),
        "nfl_rb": rule(("rushing_yards", 850, 2100, 0.60, true),
                       ("rushing_tds",     4,   28, 0.25, true),
                       ("ypc",           3.5,  6.2, 0.15, true)),
        "nfl_qb": rule(("passing_yards", 3000, 5500, 0.42, true),
                       ("passing_tds",     18,   55, 0.40, true),
                       ("interceptions",    4,   24, 0.18, false)),
        "nba_scorer": rule(("ppg",    20.0,  37.0, 0.68, true),
                           ("ts_pct", 0.500, 0.670, 0.20, true),
                           ("apg",     2.0,  11.0, 0.12, true)),
        "nba_big": rule(("ppg", 16.0, 30.0, 0.45, true),
                        ("rpg",  8.0, 15.0, 0.35, true),
                        ("bpg",  0.8,  3.7, 0.20, true)),
        "nba_playmaker": rule(("apg",     6.0,  14.5, 0.55, true),
                              ("ppg",    12.0,  34.0, 0.30, true),
                              ("ts_pct", 0.480, 0.660, 0.15, true)),

        // Fantasy-point presets (mirror grade.py `_FANTASY`). Ranked by — and displayed as —
        // the raw fantasy total; no 0–100 normalization (see grade.py docstring).
        // `nfl_fantasy` is the unified any-position formula (passing + rushing + receiving),
        // matching the daily pipeline exactly — the one shipped NFL preset, and what makes
        // cross-position pools fair. The narrower skill/QB splits remain for older content.
        "nfl_fantasy": pointsRule(("passing_yards", 0.04), ("passing_tds", 4.0),
                                  ("interceptions", -2.0), ("receptions", 1.0),
                                  ("receiving_yards", 0.1), ("receiving_tds", 6.0),
                                  ("rushing_yards", 0.1), ("rushing_tds", 6.0)),
        // Half PPR / Standard: same unified formula, reception credit dialed down (0.5) or
        // dropped entirely (Standard has no reception term at all — 0 coefficient would just
        // be a no-op line item).
        "nfl_fantasy_half": pointsRule(("passing_yards", 0.04), ("passing_tds", 4.0),
                                       ("interceptions", -2.0), ("receptions", 0.5),
                                       ("receiving_yards", 0.1), ("receiving_tds", 6.0),
                                       ("rushing_yards", 0.1), ("rushing_tds", 6.0)),
        "nfl_fantasy_standard": pointsRule(("passing_yards", 0.04), ("passing_tds", 4.0),
                                           ("interceptions", -2.0),
                                           ("receiving_yards", 0.1), ("receiving_tds", 6.0),
                                           ("rushing_yards", 0.1), ("rushing_tds", 6.0)),
        "nfl_skill_ppr": pointsRule(("receptions", 1.0), ("receiving_yards", 0.1),
                                    ("receiving_tds", 6.0), ("rushing_yards", 0.1),
                                    ("rushing_tds", 6.0)),
        "nfl_qb_fantasy": pointsRule(("passing_yards", 0.04), ("passing_tds", 4.0),
                                     ("interceptions", -2.0), ("rushing_yards", 0.1),
                                     ("rushing_tds", 6.0)),
        // NBA grades season TOTALS (derived at ingest: per-game × games) at DK-ish rates.
        "nba_fantasy": pointsRule(("points", 1.0), ("rebounds", 1.2), ("assists", 1.5),
                                  ("steals", 3.0), ("blocks", 3.0)),

        // Baseball/soccer/tennis presets (mirror grade.py `_FANTASY` byte-for-byte).
        "baseball_hitter_fantasy": pointsRule(("hits", 1.0), ("doubles", 1.0),
                                              ("triples", 2.0), ("home_runs", 3.0),
                                              ("runs", 1.0), ("rbi", 1.0),
                                              ("base_on_balls", 1.0), ("stolen_bases", 2.0)),
        "baseball_pitcher_fantasy": pointsRule(("innings_pitched", 1.0), ("strike_outs", 1.0),
                                               ("wins", 5.0), ("saves", 6.0),
                                               ("earned_runs", -1.0), ("base_on_balls", -0.5)),
        "soccer_attacker_fantasy": pointsRule(("goals", 5.0), ("assists", 3.0),
                                              ("appearances", 1.0)),
        "soccer_defender_fantasy": pointsRule(("clean_sheets", 4.0), ("goals", 6.0),
                                              ("assists", 3.0), ("appearances", 0.5)),
        "tennis_fantasy": pointsRule(("matches_won", 1.0), ("titles", 8.0),
                                     ("grand_slams", 30.0), ("matches_lost", -0.5)),
    ]

    static func preset(_ key: String) -> ScoringRule? { presets[key] }

    /// Toggle every term of this rule between fixed and era-adjusted normalization,
    /// preserving the fixed bounds as the era fallback. Points terms are absolute fantasy
    /// totals and don't era-adjust, so they pass through unchanged.
    func eraAdjusted(_ on: Bool) -> ScoringRule {
        ScoringRule(terms: terms.map { term in
            switch term.norm {
            case .fixed(let s):
                return on ? Term(stat: term.stat, weight: term.weight, higherWins: term.higherWins,
                                 norm: .eraAdjusted(fallback: s)) : term
            case .eraAdjusted(let fb):
                return on ? term : Term(stat: term.stat, weight: term.weight,
                                        higherWins: term.higherWins, norm: .fixed(fb))
            case .points(let per):
                return on ? Term(stat: term.stat, weight: term.weight, higherWins: term.higherWins,
                                 norm: .eraPoints(perUnit: per)) : term
            case .eraPoints(let per):
                return on ? term : Term(stat: term.stat, weight: term.weight,
                                        higherWins: term.higherWins, norm: .points(perUnit: per))
            }
        }, displayScale: displayScale)
    }

    private static func rule(_ specs: (String, Double, Double, Double, Bool)...) -> ScoringRule {
        ScoringRule(terms: specs.map { stat, lo, hi, weight, higherWins in
            Term(stat: stat, weight: weight, higherWins: higherWins,
                 norm: .fixed(FixedScale(lo: lo, hi: hi)))
        })
    }

    /// Build a fantasy-points rule from `(stat, perUnit)` pairs, displayed as the raw total
    /// (no `displayScale`). `weight` is unused by points grading (the coefficient lives in
    /// `perUnit`); we set it to 1 and `higherWins` to true.
    private static func pointsRule(_ specs: (String, Double)...) -> ScoringRule {
        ScoringRule(terms: specs.map { stat, perUnit in
            Term(stat: stat, weight: 1, higherWins: true, norm: .points(perUnit: perUnit))
        })
    }
}
