import Foundation

/// One Over/Under round: a real player-season stat, and a threshold ("line") the player must
/// guess whether the real number cleared. `threshold` is never equal to `actualValue` (see
/// `OverUnderRoundGenerator`) so every round has an unambiguous right answer.
struct OverUnderRound: Identifiable, Equatable {
    let id: String
    let player: CatalogSeason
    let stat: ScoringStat
    let threshold: Double

    var actualValue: Double { player.stats[stat.key] ?? 0 }
    var isOver: Bool { actualValue > threshold }
}

/// Deterministic, client-side round generation — no pipeline/content-server dependency (the
/// brief's "client-generated, no pipeline change" scope for this format). Draws from the same
/// `PlayerSeasonCatalog`/`ScoringStat` catalog the Create flow already uses.
enum OverUnderRoundGenerator {
    /// Round `index` for `sport` on `date` is the same for every install — same daily-determinism
    /// ethos as Keep4's blind order — but the sequence is effectively unbounded (arcade session,
    /// not a fixed 8 cards), since each index just re-seeds independently.
    static func round(from pool: [CatalogSeason], sport: Sport, date: Date, index: Int) -> OverUnderRound? {
        guard !pool.isEmpty else { return nil }
        var gen = SeededGenerator(seed: SeededGenerator.stableHash(
            "overunder-\(sport.rawValue)-\(dayString(date))-\(index)"))

        guard let player = pool.randomElement(using: &gen) else { return nil }
        // Position-scope the candidate stats first (same mechanism `ScoringStat.displayColumns`
        // uses) — without this, a WR's raw stat row still carries a zeroed `passing_yards` key
        // (every offensive stat column exists per row regardless of position), so an unscoped
        // presence filter would happily hand out an "Over/Under 3000 passing yards" round for a
        // receiver. `minimum: 0` matches `displayColumns`' own guard: never fall back to the
        // unsliced set just because the position filter emptied it out.
        let positionStats = sport.sliceForPosition(
            ScoringStat.catalog(for: sport), position: player.position, minimum: 0, statKey: \.key)
        let candidateStats = positionStats.filter { player.stats[$0.key] != nil }
        guard let stat = candidateStats.randomElement(using: &gen) else { return nil }
        let actual = player.stats[stat.key] ?? 0

        // Jitter the threshold 8-30% of the stat's typical range away from the true value,
        // in a random direction, clamped to the stat's plausible [lo, hi] bounds — keeps lines
        // believable per stat/era rather than wildly off (a 2 INT QB shouldn't see a 40 INT line).
        let range = max(stat.hi - stat.lo, 0.001)
        let magnitude = Double.random(in: 0.08...0.30, using: &gen) * range
        let direction: Double = Bool.random(using: &gen) ? 1 : -1
        var threshold = actual + direction * magnitude
        threshold = min(max(threshold, stat.lo), stat.hi)
        if threshold == actual {
            threshold += (direction >= 0 ? -1 : 1) * max(range * 0.05, 0.5)
        }

        return OverUnderRound(id: "\(sport.rawValue)-\(dayString(date))-\(index)",
                              player: player, stat: stat, threshold: threshold)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

/// Combo-scaled scoring — a correct guess earns more the longer the current streak, capped so
/// score can't blow up unboundedly on a very long run.
enum OverUnderScoring {
    static let basePoints = 100
    static let comboStep = 0.1
    static let comboCap = 10

    /// `consecutiveCorrect` is the streak *entering* this round (0 for the first correct guess).
    static func comboMultiplier(consecutiveCorrect: Int) -> Double {
        1.0 + Double(min(max(consecutiveCorrect, 0), comboCap)) * comboStep
    }

    static func points(consecutiveCorrectBeforeThisRound: Int) -> Int {
        Int((Double(basePoints) * comboMultiplier(consecutiveCorrect: consecutiveCorrectBeforeThisRound)).rounded())
    }
}

/// 3 free lives, regenerating 1/hour — unlimited for Pro (checked at the call site via
/// `Entitlements.hasUnlimitedOverUnderLives`, not baked into this type). Pure + clock-injected
/// so the regen math is fully unit-testable (AGENTS.md: "regen math is exactly the kind of
/// thing that ships broken untested").
struct LivesBank: Equatable {
    static let maxLives = 3
    static let regenInterval: TimeInterval = 3600

    var count: Int
    var lastLostAt: Date?

    static let initial = LivesBank(count: maxLives, lastLostAt: nil)

    var isEmpty: Bool { count <= 0 }

    /// Regenerates 1 life per full hour elapsed since the last loss, capped at `maxLives`.
    /// Advances `lastLostAt` by the consumed hours (rather than clearing it outright) when not
    /// fully regenerated, so partial progress toward the *next* life isn't lost.
    func regenerated(now: Date = Date()) -> LivesBank {
        guard count < Self.maxLives, let lastLostAt else { return self }
        let elapsed = now.timeIntervalSince(lastLostAt)
        let regenCount = Int(elapsed / Self.regenInterval)
        guard regenCount > 0 else { return self }
        let newCount = min(Self.maxLives, count + regenCount)
        let newLastLostAt: Date? = newCount == Self.maxLives ? nil
            : lastLostAt.addingTimeInterval(Double(regenCount) * Self.regenInterval)
        return LivesBank(count: newCount, lastLostAt: newLastLostAt)
    }

    func losingALife(now: Date = Date()) -> LivesBank {
        LivesBank(count: max(0, count - 1), lastLostAt: lastLostAt ?? now)
    }
}
