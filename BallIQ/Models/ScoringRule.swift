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
///   weight-normalization. Ranking is by the true fantasy total (so the audited PPR fix holds),
///   but the *displayed* grade is that total min-maxed into 0–100 via the rule's `displayScale`
///   (a strict monotonic transform — it cannot change who's Keep vs Cut, only the number shown,
///   so it reads on the same familiar scale as every other formula instead of a points total that
///   looks wildly different across sports). Points rules are homogeneous (all terms `.points`);
///   a penalty's sign lives in its coefficient (e.g. interceptions at −2), so `higherWins` is
///   ignored. A points rule with no `displayScale` set falls back to showing the raw total.
/// - `.eraPoints(perUnit)` — era-adjusted fantasy points: the raw value is scaled by a per-era
///   *volume index* (`globalMean / eraMean` for the stat) before applying the coefficient, so the
///   same production is worth more in a scarce era. Falls back to `.points` (index 1.0) when no
///   trustworthy baseline exists. Toggling `eraAdjusted` swaps `.points` ↔ `.eraPoints`.
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
    /// 0–100 display bounds for a points rule's raw fantasy total (nil → show raw points).
    /// Non-points rules ignore this; their components already self-normalize to 0–100.
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
            let raw = terms.reduce(0.0) { sum, term in
                switch term.norm {
                case .points(let perUnit):
                    return sum + (stats[term.stat] ?? 0) * perUnit
                case .eraPoints(let perUnit):
                    let idx = Self.eraIndex(stat: term.stat, sport: sport, position: position,
                                            year: seasonYear, baselines: baselines)
                    return sum + (stats[term.stat] ?? 0) * idx * perUnit
                default:
                    return sum   // fixed/era terms don't participate in a points rule
                }
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

    /// Per-era volume index for a stat: `globalMean / eraMean`, so the same production scores
    /// higher in a scarcer era. Returns 1.0 (no adjustment) when the era sample is too thin or
    /// the stat isn't in the baselines.
    static func eraIndex(stat: String, sport: Sport, position: String, year: Int,
                         baselines: StatBaselines?) -> Double {
        guard let era = baselines?.lookup(sport: sport, position: position, stat: stat, year: year),
              era.count >= minBaselineSamples, era.mean > 0,
              let global = baselines?.globalMean(sport: sport, position: position, stat: stat),
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

        // Fantasy-point presets (mirror grade.py `_FANTASY` + `_FANTASY_BOUNDS`). Ranked by the
        // raw fantasy total; displayed as that total min-maxed to 0–100 (see grade.py docstring
        // for how the bounds were anchored to real catalog percentiles).
        "nfl_skill_ppr": pointsRule(displayScale: .init(lo: 40, hi: 450),
                                    ("receptions", 1.0), ("receiving_yards", 0.1),
                                    ("receiving_tds", 6.0), ("rushing_yards", 0.1),
                                    ("rushing_tds", 6.0)),
        "nfl_qb_fantasy": pointsRule(displayScale: .init(lo: 100, hi: 450),
                                     ("passing_yards", 0.04), ("passing_tds", 4.0),
                                     ("interceptions", -2.0), ("rushing_yards", 0.1),
                                     ("rushing_tds", 6.0)),
        "nba_fantasy": pointsRule(displayScale: .init(lo: 15, hi: 75),
                                  ("ppg", 1.0), ("rpg", 1.2), ("apg", 1.5),
                                  ("spg", 3.0), ("bpg", 3.0)),
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

    /// Build a fantasy-points rule from `(stat, perUnit)` pairs, displayed as `displayScale`
    /// min-maxed to 0–100. `weight` is unused by points grading (the coefficient lives in
    /// `perUnit`); we set it to 1 and `higherWins` to true.
    private static func pointsRule(displayScale: FixedScale, _ specs: (String, Double)...) -> ScoringRule {
        ScoringRule(terms: specs.map { stat, perUnit in
            Term(stat: stat, weight: 1, higherWins: true, norm: .points(perUnit: perUnit))
        }, displayScale: displayScale)
    }
}
