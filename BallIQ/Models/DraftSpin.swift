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
    /// Soccer only: restrict spins to one league (`DraftSpinConstraint.majorSoccerLeagues`
    /// value, e.g. "England"). nil = any of the ~38 countries' top flights the catalog
    /// carries — see that constant's doc comment for why the setup screen only offers a
    /// curated subset rather than every ingested league.
    var soccerLeague: String? = nil

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

    /// One selectable league on the Draft & Spin setup screen: `value` is matched exactly
    /// against `CatalogSeason.league` (the country label `espn_soccer.py` writes — see its
    /// `_LEAGUES` dict), and `name` is the competition shown on the chip.
    ///
    /// The two are kept separate deliberately: the stored data is tagged by COUNTRY (top
    /// flight of ESPN's `.1` slug), so filtering on the country value stays correct even if a
    /// country's rows ever turn out to include something other than its single top division —
    /// whereas a hardcoded "Premier League" *label* would silently misdescribe such rows. So we
    /// show the competition name the player expects, but never filter on it.
    struct SoccerLeague: Equatable, Hashable { let value: String, name: String }

    /// The setup screen's LEAGUE picker offers this curated subset of the ~38 countries' top
    /// flights `espn_soccer.py` ingests, not all of them — real coverage varies a lot by league
    /// (some only just started backfilling), and a picker listing every country would mostly
    /// produce empty/thin drafts. These are the leagues expected to have real, useful depth;
    /// `spinRound`'s own graceful fallback (below) still covers the case where a chosen league is
    /// thinner than expected for a given round.
    static let majorSoccerLeagues = [
        SoccerLeague(value: "England",     name: "Premier League"),
        SoccerLeague(value: "Spain",       name: "La Liga"),
        SoccerLeague(value: "Germany",     name: "Bundesliga"),
        SoccerLeague(value: "Italy",       name: "Serie A"),
        SoccerLeague(value: "France",      name: "Ligue 1"),
        SoccerLeague(value: "USA (MLS)",   name: "MLS"),
        SoccerLeague(value: "Netherlands", name: "Eredivisie"),
        SoccerLeague(value: "Portugal",    name: "Primeira Liga"),
        SoccerLeague(value: "Brazil",      name: "Brasileirão"),
        SoccerLeague(value: "Mexico",      name: "Liga MX"),
    ]

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
    /// candidates are players you already own. `league` (soccer LEAGUE setup option)
    /// restricts the spin to `CatalogSeason.league == league`; same never-dead-end shape as
    /// `lockedTeam` — a league with thin/not-yet-backfilled coverage for the currently open
    /// roles falls back to the full pool rather than showing nothing.
    static func spinRound(from pool: [CatalogSeason], sport: Sport, openRoles: [String],
                        lockedTeam: String? = nil, usedLockedYears: Set<Int> = [],
                        excludeNames: Set<String> = [], league: String? = nil,
                        using gen: inout some RandomNumberGenerator) -> (team: String, year: Int)? {
        let openFilters = (formations[sport] ?? []).filter { openRoles.contains($0.role) }.map(\.filter)
        guard !openFilters.isEmpty else { return nil }

        func viableCombos(in seasons: [CatalogSeason]) -> [TeamYear] {
            var eligibleByCombo: [TeamYear: Bool] = [:]
            for season in seasons where !season.teamAbbr.isEmpty && !excludeNames.contains(season.name) {
                let key = TeamYear(team: season.teamAbbr, year: season.seasonYear)
                if eligibleByCombo[key] == true { continue }
                eligibleByCombo[key] = openFilters.contains { $0.matches(season.position) }
            }
            return eligibleByCombo.compactMap { combo, isEligible in isEligible ? combo : nil }
        }

        var viable: [TeamYear]
        if let league {
            let narrowed = viableCombos(in: pool.filter { $0.league == league })
            viable = narrowed.isEmpty ? viableCombos(in: pool) : narrowed
        } else {
            viable = viableCombos(in: pool)
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

    /// Daily Draft mode (backlog #4): every player who opens Daily Draft on the same UTC day
    /// must see the identical round-1 (team, year) spin, so scores are comparable — seeded by
    /// day + round index only, no reroll dimension (Daily Draft has no reroll, see
    /// `DraftSpinView`). This resurrects the *seed shape* of the original date-seeded design
    /// (retired 2026-07-09 for free play — see git history on this file, commit a3916fc — free
    /// play is truly random by explicit product decision and stays that way; only this daily
    /// path is seeded again). **Determinism caveat, inherited from that same retired design:**
    /// `spinRound`'s `excludeNames`/`lockedTeam`/`usedLockedYears` arguments still shape the
    /// viable-combo pool, so once two players' prior picks diverge (different players drafted
    /// into the same open role), a later round's spin can diverge too even off the same seed.
    /// Same seed guarantees the same spin *given the same prior picks* — not an unconditional
    /// guarantee across every possible play history.
    static func dailyDraftRoundGenerator(sport: Sport, date: Date, roundIndex: Int) -> SeededGenerator {
        let day = OverUnderRoundGenerator.dayString(date)
        return SeededGenerator(seed: SeededGenerator.stableHash(
            "draftspin-dailydraft-\(sport.rawValue)-\(day)-\(roundIndex)"))
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
                case .champion: return String(localized: "CHAMPION")
                case .madePlayoffs: return String(localized: "MADE THE PLAYOFFS")
                case .missedPlayoffs: return String(localized: "MISSED THE PLAYOFFS")
                }
            case .soccer:
                switch self {
                case .champion: return String(localized: "WON THE LEAGUE")
                case .madePlayoffs: return String(localized: "TOP FOUR")
                case .missedPlayoffs: return String(localized: "MID-TABLE")
                }
            case .tennis:
                switch self {
                case .champion: return String(localized: "YEAR-END No. 1")
                case .madePlayoffs: return String(localized: "TOP 10 SEASON")
                case .missedPlayoffs: return String(localized: "TOUR GRIND")
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
/// XP-only (a simulated season must never move the competitive ladder).
///
/// Scoring basis retired 2026-07-13: the original duel formula (through 2026-07-08) scaled the
/// opponent's score by the player's own lineup power, so draft quality never affected the
/// record; the 2026-07-09 fix moved to a `power`-based (0...1, `ScoringStat`-normalized) win
/// probability, but live feedback afterward ("still too harsh") showed that abstraction wasn't
/// legible — a fan can't tell what "0.3 power" means. This version scores lineups on the exact
/// same currency a K4C4 grade uses: real fantasy points, via `ScoringRule`'s own presets
/// (`fantasyPoints`). Win probability is anchored directly against real percentiles of that same
/// stat pulled live from the catalog (`fantasyAnchors`) — "how good is my draft" now reads on a
/// scale a fan already recognizes, and the calibration is provably centered on the real
/// population instead of a hand-tuned baseline.
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

    /// Real fantasy-point percentiles (p50/p90/p99) for a FULL Draft & Spin lineup, summed
    /// across every formation slot in `DraftSpinConstraint.formations` — pulled 2026-07-13 via
    /// live SQL against the `player_seasons` catalog, one query per sport, using the exact same
    /// `ScoringRule` fantasy-point formulas `fantasyPoints` calls per player below (a qualified-
    /// season floor per sport — games/appearances/innings — mirrors the methodology behind the
    /// NFL bounds in docs/scoring-and-grading.md). p50 = a normal, unremarkable lineup (half of
    /// all real qualified seasons score below this); p90 = a well-drafted lineup; p99 = an
    /// all-time-great, "undefeated-caliber" lineup — nothing in the catalog beats it except a
    /// handful of freak outlier seasons. Re-run the same query shape if the catalog population
    /// changes materially (new sport, big backfill).
    struct FantasyAnchors { let p50: Double, p90: Double, p99: Double }

    static func fantasyAnchors(for sport: Sport) -> FantasyAnchors {
        switch sport {
        case .nfl:      return FantasyAnchors(p50: 534,   p90: 1265,  p99: 1880)
        case .nba:      return FantasyAnchors(p50: 6112,  p90: 13846, p99: 20192)
        case .baseball: return FantasyAnchors(p50: 1973,  p90: 3005,  p99: 3942)
        case .soccer:   return FantasyAnchors(p50: 368.5, p90: 677,   p99: 1024.25)
        case .tennis:   return FantasyAnchors(p50: 34.5,  p90: 165,   p99: 532.5)
        }
    }

    /// Which K4C4 fantasy-point preset (`ScoringRule.presets`) grades this player-season — the
    /// same formula a Keep4/Cut4 puzzle grades it with (`docs/scoring-and-grading.md`). NFL uses
    /// the unified any-position formula (passing+rushing+receiving all in one) since a lineup
    /// mixes QB with skill positions; baseball and soccer split by role the same way the K4C4
    /// themes do (hitter/pitcher, attacker/defender — `MF`/`FW` share the attacker formula,
    /// `DF`/`GK` the defender one, matching `themes.py`'s `soccer-attackers`/`soccer-defenders`).
    private static func fantasyPresetKey(_ season: CatalogSeason) -> String {
        switch season.sport {
        case .nfl: return "nfl_fantasy"
        case .nba: return "nba_fantasy"
        case .baseball: return season.position == "P" ? "baseball_pitcher_fantasy" : "baseball_hitter_fantasy"
        case .soccer: return (season.position == "DF" || season.position == "GK")
            ? "soccer_defender_fantasy" : "soccer_attacker_fantasy"
        case .tennis: return "tennis_fantasy"
        }
    }

    /// A player-season's real fantasy-point total, via the exact K4C4 formula for its sport/role.
    static func fantasyPoints(_ season: CatalogSeason) -> Double {
        ScoringRule.preset(fantasyPresetKey(season))?.grade(season) ?? 0
    }

    /// Per-game win chance from the lineup's total real fantasy points, piecewise-linear against
    /// this sport's own p50/p90/p99 anchors (see `fantasyAnchors`): a merely-average lineup
    /// (p50) still wins more than it loses, a well-drafted one (p90) clearly contends, and an
    /// all-time-great one (p99+) is a near-lock — but never a guaranteed sweep or wipeout
    /// (clamped 0.30...0.93).
    static func winProbability(lineupTotal: Double, sport: Sport) -> Double {
        let a = fantasyAnchors(for: sport)
        if lineupTotal < a.p50 {
            let t = min(max(lineupTotal / max(a.p50, 1), 0), 1)
            return 0.30 + 0.25 * t
        } else if lineupTotal < a.p90 {
            let t = (lineupTotal - a.p50) / max(a.p90 - a.p50, 1)
            return 0.55 + 0.20 * t
        } else {
            let t = min(max((lineupTotal - a.p90) / max(a.p99 - a.p90, 1), 0), 1)
            return 0.75 + 0.18 * t
        }
    }

    static func simulate(lineup: [CatalogSeason], sport: Sport,
                         using gen: inout some RandomNumberGenerator) -> DraftSpinResult {
        let shape = seasonShape(for: sport)
        let lineupTotal = lineup.reduce(0.0) { $0 + fantasyPoints($1) }
        let winChance = winProbability(lineupTotal: lineupTotal, sport: sport)
        // `gameCount` already matches this sport's real season length, so this is literally
        // "this roster's real season fantasy total, spread across a real season's games" — the
        // simulated PTS total a player sees lands close to a number their own picks actually
        // earned, not an abstract scaled score.
        let perGame = lineupTotal / Double(shape.gameCount)
        var wins = 0
        var totalPoints = 0.0
        for _ in 0..<shape.gameCount {
            if Double.random(in: 0..<1, using: &gen) < winChance { wins += 1 }
            totalPoints += perGame * Double.random(in: 0.7...1.3, using: &gen)
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
