import Foundation

/// One lineup slot to fill: a role label (e.g. "QB", "FLEX") and, once assigned, the picked
/// player. Distinct from a round — a round spins a (team, year) and shows its whole roster;
/// the player then assigns their pick to whichever open slot's role their real position fits.
struct DraftSpinLineupSlot: Identifiable, Equatable {
    let id: String
    let role: String
    var pick: CatalogSeason?
}

/// A real (team, year) combination this round spun, and its complete real roster.
struct DraftSpinRound: Equatable {
    let team: String
    let year: Int
    let roster: [CatalogSeason]

    static func == (lhs: DraftSpinRound, rhs: DraftSpinRound) -> Bool {
        lhs.team == rhs.team && lhs.year == rhs.year && lhs.roster.map(\.id) == rhs.roster.map(\.id)
    }
}

/// Which real position(s) satisfy a lineup role.
enum RoleFilter: Equatable {
    case exact(String)
    case anyOf([String])
    func matches(_ position: String) -> Bool {
        switch self {
        case .exact(let p): return position == p
        case .anyOf(let ps): return ps.contains(position)
        }
    }
}

private struct TeamYear: Hashable {
    let team: String
    let year: Int
}

/// Pre-game options chosen on the setup screen (reference app's config, mapped onto what
/// this catalog can honestly support — its "Roster: Both sides" toggle is display-only
/// here because the catalog carries no defensive players for any sport).
struct DraftSpinSettings: Equatable {
    /// false = every round spins any viable franchise; true = after the first round's spin,
    /// every later round spins a different YEAR of that same franchise (falling back to any
    /// team for a round where the locked team has no viable year left — never a dead spin).
    var lockToOneTeam = false
    /// true (reference "Season variations: On") = a player you already drafted can appear
    /// again in a later round as a different season of themselves; false ("Prime only") =
    /// each real player appears in your draft at most once.
    var allowSeasonVariations = true

    static let `default` = DraftSpinSettings()
}

/// Procedural draft: spin a (team, year) each round, browse that real roster with full visible
/// stats, then assign your pick to whichever open lineup slot their position fits — spin again
/// for the next slot. Repeats for the sport's lineup size.
enum DraftSpinConstraint {
    /// Real per-sport lineup shapes — one entry per round/slot to fill this session. NFL matches
    /// a standard single-flex-heavy fantasy lineup (QB/RB/WR/TE/FLEX/FLEX, 6 slots). NBA's
    /// "Starting 5" is G/G/F/F/C — the catalog only distinguishes G/F/C (no PG/SG/SF/PF split),
    /// so this is the truest realization of "Starting 5" the data can support. Soccer
    /// (GK/DF/DF/MF/MF/MF/FW/FW, 8 slots) is the largest formation the data can ever fill —
    /// live-checked club-level depth shows only 2 clubs in the whole catalog (Chelsea,
    /// Liverpool) have ever had a real DF row at all, so a literal 11-man "Starting XI" isn't
    /// achievable without fabricating data; a round that can't find a real DF just won't spin
    /// one in (see `spinRound`'s open-role requirement). Baseball (4 Hitters + 2 Pitchers) — the
    /// catalog only has H/P granularity, no batting-order positions to build a literal card
    /// from. Tennis has no per-slot formation (see `DraftSpinView`'s tennis-specific handling).
    static let formations: [Sport: [(role: String, filter: RoleFilter)]] = [
        .nfl: [("QB", .exact("QB")), ("RB", .exact("RB")), ("WR", .exact("WR")), ("TE", .exact("TE")),
               ("FLEX", .anyOf(["RB", "WR", "TE"])), ("FLEX", .anyOf(["RB", "WR", "TE"]))],
        .nba: [("G", .exact("G")), ("G", .exact("G")), ("F", .exact("F")), ("F", .exact("F")),
               ("C", .exact("C"))],
        .soccer: [("GK", .exact("GK")), ("DF", .exact("DF")), ("DF", .exact("DF")),
                  ("MF", .exact("MF")), ("MF", .exact("MF")), ("MF", .exact("MF")),
                  ("FW", .exact("FW")), ("FW", .exact("FW"))],
        .baseball: [("Hitter", .exact("H")), ("Hitter", .exact("H")), ("Hitter", .exact("H")),
                    ("Hitter", .exact("H")), ("Pitcher", .exact("P")), ("Pitcher", .exact("P"))],
        .tennis: [("Player", .exact("Player")), ("Player", .exact("Player")), ("Player", .exact("Player"))],
    ]

    static func lineupSlots(for sport: Sport) -> [DraftSpinLineupSlot] {
        (formations[sport] ?? []).enumerated().map { index, def in
            DraftSpinLineupSlot(id: "\(sport.rawValue)-slot-\(index)", role: def.role, pick: nil)
        }
    }

    /// Deterministic per day — every install spins the same sport on the same date. Uses
    /// `next()` directly with modulo rather than `randomElement(using:)`, which introduces a
    /// measurable bias toward `.soccer` with this generator (24% vs. 20% expected).
    static func sportOfTheDay(_ date: Date) -> Sport {
        let day = OverUnderRoundGenerator.dayString(date)
        var gen = SeededGenerator(seed: SeededGenerator.stableHash("draftspin-sport-\(day)"))
        let sports = Sport.allCases
        return sports[Int(gen.next() % UInt64(sports.count))]
    }

    /// Spins a real (team, year) for this round from a *sample* pool — **truly random per
    /// spin** (explicit product decision 2026-07-09, replacing the original date-seeded
    /// same-spin-on-every-install design): the RNG is injected so gameplay uses the system
    /// generator while tests stay reproducible with a `SeededGenerator`. Requires at least
    /// one real candidate that fits one of the *currently open* lineup roles, so a round can
    /// never spin a team/year where nothing is placeable. The sample only needs to be broad
    /// enough to discover a good combo; the caller re-fetches that exact (team, year)'s
    /// complete roster before showing it (see `DraftSpinView.spinNextRound` — the same
    /// sample-vs-complete-roster distinction that mattered for the single-spin design).
    /// `lockedTeam` (one-team mode) restricts the spin to that franchise's years; if the lock
    /// leaves nothing viable the spin falls back to every team rather than dead-ending.
    /// `excludeNames` (season-variations OFF) treats already-drafted players as absent when
    /// judging a combo viable, so a spin can never land on a roster whose only placeable
    /// candidates are players you already own.
    static func spinRound(from pool: [CatalogSeason], sport: Sport, openRoles: [String],
                        lockedTeam: String? = nil, usedLockedYears: Set<Int> = [],
                        excludeNames: Set<String> = [],
                        using gen: inout some RandomNumberGenerator) -> (team: String, year: Int)? {
        let openFilters = (formations[sport] ?? []).filter { openRoles.contains($0.role) }.map(\.filter)
        guard !openFilters.isEmpty else { return nil }

        var eligibleByCombo: [TeamYear: Bool] = [:]
        for season in pool where !season.teamAbbr.isEmpty && !excludeNames.contains(season.name) {
            let key = TeamYear(team: season.teamAbbr, year: season.seasonYear)
            if eligibleByCombo[key] == true { continue }
            eligibleByCombo[key] = openFilters.contains { $0.matches(season.position) }
        }
        var viable: [TeamYear] = []
        for (combo, isEligible) in eligibleByCombo where isEligible {
            viable.append(combo)
        }
        if let lockedTeam {
            // Different year each round for the locked franchise; fall back to other teams
            // only when the lock has no fresh viable year left (never re-spin a used year).
            let locked = viable.filter { $0.team == lockedTeam && !usedLockedYears.contains($0.year) }
            if !locked.isEmpty {
                viable = locked
            } else {
                viable.removeAll { $0.team == lockedTeam }
            }
        }
        // Sorting before the draw still matters even with a random RNG: `Dictionary`
        // iteration order varies run to run, so a seeded test generator would otherwise
        // see a different candidate order (and thus a different pick) per run.
        viable.sort { lhs, rhs in
            lhs.team == rhs.team ? lhs.year < rhs.year : lhs.team < rhs.team
        }
        guard !viable.isEmpty else { return nil }
        // `next()` + modulo, not `randomElement(using:)` — same rationale as
        // `sportOfTheDay`: randomElement is measurably biased under SeededGenerator.
        let chosen = viable[Int(gen.next() % UInt64(viable.count))]
        return (chosen.team, chosen.year)
    }

    /// Which of `openSlots` a real `position` can be assigned to.
    static func eligibleSlots(for position: String, in openSlots: [DraftSpinLineupSlot], sport: Sport) -> [DraftSpinLineupSlot] {
        let filtersByRole = Dictionary((formations[sport] ?? []).map { ($0.role, $0.filter) }, uniquingKeysWith: { a, _ in a })
        return openSlots.filter { slot in
            guard let filter = filtersByRole[slot.role] else { return false }
            return filter.matches(position)
        }
    }
}

/// Outcome of a simulated season for a drafted lineup. The three cases are semantic tiers
/// (best/middle/bottom) shared by every sport; only the display title varies per sport. Raw
/// values stay stable — they're stringified into analytics.
struct DraftSpinResult: Equatable {
    enum Outcome: String, CaseIterable { case champion, madePlayoffs, missedPlayoffs

        /// Sport-appropriate wording: US leagues have playoffs; a soccer league season ends
        /// in a table position; a tennis "season" is a tour campaign, not head-to-head play.
        func title(for sport: Sport) -> String {
            switch sport {
            case .nfl, .nba, .baseball:
                switch self {
                case .champion: return "CHAMPION"
                case .madePlayoffs: return "MADE THE PLAYOFFS"
                case .missedPlayoffs: return "MISSED THE PLAYOFFS"
                }
            case .soccer:
                switch self {
                case .champion: return "WON THE LEAGUE"
                case .madePlayoffs: return "TOP FOUR"
                case .missedPlayoffs: return "MID-TABLE"
                }
            case .tennis:
                switch self {
                case .champion: return "YEAR-END No. 1"
                case .madePlayoffs: return "TOP 10 SEASON"
                case .missedPlayoffs: return "TOUR GRIND"
                }
            }
        }
    }

    let wins: Int
    let losses: Int
    let totalPoints: Int
    let outcome: Outcome
}

/// Pure season simulator, RNG-injected (system generator in gameplay — every run is a fresh
/// season, matching the now-truly-random spins; seeded generator in tests). Still unranked/
/// XP-only (a simulated season must never move the competitive ladder), but no longer
/// pure-luck: the 2026-07-09 scoring audit found the original duel formula scaled the
/// opponent's score by the player's own lineup power, so draft quality mathematically never
/// affected the record — every lineup was a coin flip. Now lineup power sets the per-game
/// win probability directly (see `winProbability`), so drafting well genuinely wins more.
enum DraftSpinSimulator {
    /// A sport's season length and the win counts that separate its three outcome tiers.
    /// Thresholds are matched by *tier probability* under a coin-flip (50/50) week, not by
    /// copying NFL's win ratio — at 50/50 odds, a ratio like "12 of 17" (~71%) applied to an
    /// 82-game NBA season would put the champion tier at ~58 wins, needed with ~0% probability.
    /// Matching NFL's actual tier odds (champion ≈ 7% of seasons, playoffs ≈ 50%) keeps every
    /// sport's outcome distribution comparable. NFL itself is unchanged (17/12/9) so the
    /// locked-value regression test below still pins its historical RNG output exactly.
    struct SeasonShape {
        let gameCount: Int
        let championshipWins: Int
        let playoffWins: Int
    }

    static func seasonShape(for sport: Sport) -> SeasonShape {
        switch sport {
        case .nfl: return SeasonShape(gameCount: 17, championshipWins: 12, playoffWins: 9)
        case .nba: return SeasonShape(gameCount: 82, championshipWins: 48, playoffWins: 42)
        case .baseball: return SeasonShape(gameCount: 162, championshipWins: 91, playoffWins: 81)
        case .soccer: return SeasonShape(gameCount: 38, championshipWins: 24, playoffWins: 19)
        case .tennis: return SeasonShape(gameCount: 70, championshipWins: 42, playoffWins: 35)
        }
    }

    /// The lineup power at which a season is a coin flip. Calibrated against real drafts:
    /// `power` normalizes each stat against `ScoringStat`'s reference bounds, so a lineup of
    /// respectable-but-unspectacular seasons averages ≈0.4; stars push toward 0.6+.
    static let leagueBaselinePower = 0.40

    /// Per-game win chance from lineup power — linear around the baseline, clamped so no
    /// season is ever a guaranteed sweep or wipeout (an all-star lineup can still miss, a
    /// bad one can still shock): +0.1 lineup power ≈ +9 points of per-game win chance.
    /// At the tiers' own thresholds: champion (e.g. NFL 12 of 17, ~71% wins) needs a
    /// sustained ~0.7+ per-game chance ⇒ power ≈ 0.73 — a genuinely elite draft; playoffs
    /// (~53%) ⇒ power ≈ 0.43 — a solid one. That's the audit's target shape: better drafts
    /// win visibly more, luck still swings any single season.
    static func winProbability(power: Double) -> Double {
        min(max(0.5 + 0.9 * (power - leagueBaselinePower), 0.10), 0.90)
    }

    static func simulate(lineup: [CatalogSeason], sport: Sport,
                         using gen: inout some RandomNumberGenerator) -> DraftSpinResult {
        let shape = seasonShape(for: sport)
        let basePower = lineup.isEmpty ? 0 : lineup.map { power($0, sport: sport) }.reduce(0, +) / Double(lineup.count)
        let winChance = winProbability(power: basePower)
        var wins = 0
        var totalPoints = 0.0
        for _ in 0..<shape.gameCount {
            if Double.random(in: 0..<1, using: &gen) < winChance { wins += 1 }
            totalPoints += basePower * 100 * Double.random(in: 0.7...1.3, using: &gen)
        }
        let losses = shape.gameCount - wins
        let outcome: DraftSpinResult.Outcome = wins >= shape.championshipWins ? .champion
            : wins >= shape.playoffWins ? .madePlayoffs : .missedPlayoffs
        return DraftSpinResult(wins: wins, losses: losses, totalPoints: Int(totalPoints.rounded()), outcome: outcome)
    }

    /// A season's overall strength as a single 0...1 value: the mean of every catalog stat this
    /// player-season has, each normalized against `ScoringStat`'s own reference bounds and
    /// oriented so "higher is always better" (mirrors `ScoringRule`'s `.fixed` normalization —
    /// reusing the same bounds rather than inventing a parallel scale).
    static func power(_ season: CatalogSeason, sport: Sport) -> Double {
        let normalized: [Double] = ScoringStat.catalog(for: sport).compactMap { stat in
            guard let raw = season.stats[stat.key] else { return nil }
            let unit = (raw - stat.lo) / max(stat.hi - stat.lo, 0.001)
            let oriented = stat.higherWins ? unit : 1 - unit
            return min(max(oriented, 0), 1)
        }
        guard !normalized.isEmpty else { return 0.3 }
        return normalized.reduce(0, +) / Double(normalized.count)
    }
}
