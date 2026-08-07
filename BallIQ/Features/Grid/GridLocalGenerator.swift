import Foundation

/// Generates Grid boards on-device from `GridMembershipIndex`, so practice play is endless and
/// works offline instead of re-serving the 41 boards the server has ever minted.
///
/// # Scope: practice only, and that is a correctness boundary, not a product one
///
/// This is a **second generator**. `tools/ingest/grid.py` is and stays the authority: it mints the
/// daily ranked board, its output is immutable for its day, and every player sees the same one.
/// Two generators can drift, so this one is wired *only* into `GridGameView`'s practice path
/// (`isPractice`), which already awards nothing — no rating, no XP, no arcade score, no
/// crowd-rarity log. If this generator and grid.py ever disagree, the disagreement cannot reach
/// ranked play, a leaderboard, or another player's score.
///
/// # What it mirrors, and what it deliberately doesn't
///
/// It reproduces grid.py's **rules**, not its code:
///
///   * All five archetypes, once the index carries axes (v2, migration 0012). `teams-x-decades`
///     and `teams-x-teams` need nothing but the membership relation; the other three additionally
///     need to know which *seasons* cleared "30+ Pass TD" or were played at QB, which is what
///     `GridMembershipIndex.axes`/`axisMemberships` now supply. A v1 payload — a cached one from
///     a previous build, or a sport whose catalog satisfies no axis — still generates, just from
///     the first two shapes, exactly as this file behaved before v2 existed.
///
///     Crucially the thresholds are NOT mirrored here. `grid_axes._STATS` stays the only place
///     "1,000+ Rush Yds" is defined; the pipeline evaluates those `Filter`s in Python and ships
///     the *result*, so a retuned threshold cannot leave the practice board asking a different
///     question than the daily one under the same label.
///   * The season/career grain split (see `GridMembershipTables`).
///   * `teams-x-teams` is gated on the same team-mobile sports grid_axes.py gates it on, so
///     tennis never gets one — its "teams" are countries and players don't change nationality,
///     which would make every cell unviable. Tennis still gets `teams-x-decades`, which is the
///     shape its server boards already have.
///   * The prominence cap on the team × team pool, the same 60.
///   * `rarityStars`, bucketed on the same 1/3/7/14 boundaries — and identically, not merely
///     similarly: grid.py derives stars from the **graded pool** (`player_seasons`), which is the
///     same population this index is built from.
///   * Axis `key` strings, so a locally-generated board's combo identity means the same thing as
///     a server board's in `grid_history` terms.
///
/// One honest difference, worth knowing before comparing a practice board to a daily one: NFL
/// daily boards widen cell *validity* with full rosters (`nfl_rosters`, ~69k memberships of
/// players with no stat line). That data isn't in `player_seasons` and so isn't in this index, so
/// an NFL practice cell accepts the graded pool only — a narrower answer set, never a wider one.
/// Stars are unaffected, because grid.py computes them from the graded pool too.
struct GridLocalGenerator {
    /// Board shapes this generator can build. Weights are `grid.py`'s own, carried over rather
    /// than re-invented, so a practice rotation feels like the daily one.
    ///
    /// `decades-x-stats` is deliberately absent even though the index could now drive it: it is
    /// the one shape whose viability swings hard by sport, and `grid.py` gates it on a
    /// combo-space check against the 60-day server history window — a window this generator has
    /// no equivalent of (practice de-dupes per session, not per fortnight). Offering it here
    /// without that guard is how tennis ends up serving the same three columns every re-roll.
    enum Archetype: String, CaseIterable {
        case teamsXDecades = "teams-x-decades"
        case teamsXTeams = "teams-x-teams"
        case teamsXStats = "teams-x-stats"
        case teamsXMixed = "teams-x-mixed"
        case mixedXTeams = "mixed-x-teams"

        var weight: Int {
            // Mirrors grid.py's ARCHETYPES weights (2026-08-07 diversity rebalance): the two
            // heterogeneous shapes dominate, stat/decade shapes are the strong middle, and
            // all-teams is a rare change of pace. Keep in lockstep with the server rotation —
            // the whole point is that daily and practice offer the same mix.
            switch self {
            case .teamsXMixed, .mixedXTeams: return 5
            case .teamsXStats: return 3
            case .teamsXDecades: return 2
            case .teamsXTeams: return 1
            }
        }

        /// Whether this shape needs `GridMembershipIndex.axes`. The first two don't, which is why
        /// a v1 payload still generates.
        var needsAxes: Bool {
            switch self {
            case .teamsXDecades, .teamsXTeams: return false
            case .teamsXStats, .teamsXMixed, .mixedXTeams: return true
            }
        }
    }

    /// Sports where `team_abbr` is a franchise a player can actually move between — the same set
    /// as `grid_axes.TEAM_MOBILE_SPORTS`, and excluded for the same reason: tennis stores the
    /// player's *country*, fixed for a career, so "played for both USA and CRO" has no answers.
    static let teamMobileSports: Set<Sport> = [.nfl, .nba, .baseball, .soccer]

    /// How many teams a team × team board may draw from, ranked by distinct player count.
    /// `grid.py`'s `TEAM_X_TEAM_POOL`.
    static let teamXTeamPool = 60

    /// `grid.py`'s `max_attempts`. Soccer is genuinely marginal — most club pairings share no
    /// player — so the budget has to be generous or a viable board gets missed.
    static let maxAttempts = 500

    /// `grid.py`'s `MAX_CELL_ANSWERS`. Mirrored because the shapes that need it are exactly the
    /// ones this generator just gained: a position axis is the loosest thing on the board
    /// ("KC × RB" is every running back the club ever had), and without a ceiling a practice
    /// board would happily serve a cell nobody could get wrong. The floor (>=1 answer) was
    /// already here; this is its other half.
    static let maxCellAnswers = 200

    let tables: GridMembershipTables
    /// Resolves the nation code a league-scoped team label carries ("MCI-ENG"). Injected so the
    /// tests don't depend on a warmed identity index.
    private let leagueCode: (String) -> String

    init(index: GridMembershipIndex,
         leagueCode: @escaping (String) -> String = GridLocalGenerator.nationCode) {
        self.tables = GridMembershipTables(index)
        self.leagueCode = leagueCode
    }

    private var sport: Sport { tables.index.sport }

    /// Which archetypes this sport's data can actually offer. Filtering up front rather than
    /// inside the retry loop is grid.py's own fix for a real bug: an attempt that draws an
    /// impossible shape burns a retry that can never succeed, and that is what pushed tennis and
    /// soccer from "a board" to "no viable grid" on 2026-07-27.
    var feasibleArchetypes: [Archetype] {
        var out: [Archetype] = []
        let teamMobile = Self.teamMobileSports.contains(sport) && tables.teamsByProminence.count >= 3
        if tables.index.teams.count >= 3 && tables.decades.count >= 3 { out.append(.teamsXDecades) }
        if teamMobile { out.append(.teamsXTeams) }
        // Everything below needs the v2 payload. A v1 index (a cached one from a previous build,
        // or a sport whose catalog satisfies no axis) simply keeps the two shapes above.
        guard tables.index.hasAxes else { return out }
        if tables.index.teams.count >= 3 && milestones(kind: "stat").count >= 3 {
            out.append(.teamsXStats)
        }
        if tables.index.teams.count >= 3 && mixedPool.count >= 3 { out.append(.teamsXMixed) }
        // `mixed_any` must face an all-team dimension, so this shape needs the career-grain team
        // pool the same way teams-x-teams does — which is why tennis never gets it.
        if teamMobile && mixedAnyPool.count >= 3 { out.append(.mixedXTeams) }
        return out
    }

    /// A generated board plus the identity the caller feeds back in as `recentlyServed`. The key
    /// travels with the board rather than being re-derived from it: `GridPuzzle.GridAxis` carries
    /// the *rendered* label ("1990s", "MCI-ENG"), and reconstructing an axis key by unpicking a
    /// display string is exactly the kind of second source of truth that drifts.
    struct Board {
        let puzzle: GridPuzzle
        let comboKey: String
    }

    /// A board, or nil when this sport's data can't produce one.
    ///
    /// `seed` makes generation reproducible — same seed, same board — which is what lets a test
    /// pin a shape and what would let a board be shared by seed later. `recentlyServed` holds
    /// `comboKey` values already played this session, so a re-roll never hands back a board the
    /// player just finished. Both mirror grid.py's retry loop, which rejects on exactly these
    /// conditions.
    func board(seed: UInt64, recentlyServed: Set<String> = []) -> Board? {
        let feasible = feasibleArchetypes
        guard !feasible.isEmpty else { return nil }
        let rotation = feasible.flatMap { Array(repeating: $0, count: $0.weight) }

        for attempt in 0..<Self.maxAttempts {
            var rng = SeededGenerator(seed: seed &+ UInt64(attempt))
            let archetype = rotation[Int(rng.next() % UInt64(rotation.count))]
            guard let (rows, cols) = axes(for: archetype, rng: &rng) else { continue }
            // The same axis on a row and a column produces a degenerate cell ("KC and KC").
            if !Set(rows.map(\.key)).isDisjoint(with: Set(cols.map(\.key))) { continue }
            let combo = Self.comboKey(rows: rows, cols: cols)
            if recentlyServed.contains(combo) { continue }
            guard let cells = cells(archetype: archetype, rows: rows, cols: cols) else { continue }
            return Board(puzzle: GridPuzzle(sport: sport,
                                            rows: rows.map(\.axis), cols: cols.map(\.axis),
                                            cells: cells, archetype: archetype.rawValue),
                         comboKey: combo)
        }
        return nil
    }

    /// Order-independent identity of a board's axis sets — the Swift twin of `grid.combo_key`.
    static func comboKey(rows: [LocalAxis], cols: [LocalAxis]) -> String {
        rows.map(\.key).sorted().joined(separator: "|") + "||"
            + cols.map(\.key).sorted().joined(separator: "|")
    }

    // MARK: - Axes

    /// An axis plus the index-space handle needed to resolve its player set. `GridPuzzle.GridAxis`
    /// alone isn't enough — it carries what *renders*, not which id to intersect on. Exactly one
    /// of the three handles is set; `kind` says which.
    struct LocalAxis {
        let axis: GridPuzzle.GridAxis
        let key: String
        /// Team index into `GridMembershipIndex.teams`.
        var team: Int? = nil
        /// Decade (1990, 2000, …).
        var decade: Int? = nil
        /// Index into `GridMembershipIndex.axes` — a stat or position milestone.
        var milestone: Int? = nil
    }

    /// Indices into `index.axes` of one kind, in payload order so a seeded draw is reproducible.
    private func milestones(kind: String) -> [Int] {
        tables.index.axes.indices.filter { tables.index.axes[$0].kind == kind }
    }

    /// The `mixed` dimension: every non-team kind at once. `grid_axes`' own composition.
    private var mixedPool: [LocalAxis] {
        milestones(kind: "position").map(milestoneAxis)
            + milestones(kind: "stat").map(milestoneAxis)
            + tables.decades.map(decadeAxis)
    }

    /// The `mixed_any` dimension: `mixed` plus career-grain teams. Legal only opposite an
    /// all-team dimension, which `mixedXTeams` is — see `grid.py`'s ARCHETYPES comment.
    private var mixedAnyPool: [LocalAxis] {
        tables.teamsByProminence.prefix(Self.teamXTeamPool).map(teamAxis) + mixedPool
    }

    private func axes(for archetype: Archetype,
                      rng: inout SeededGenerator) -> (rows: [LocalAxis], cols: [LocalAxis])? {
        switch archetype {
        case .teamsXDecades:
            let teams = sample(Array(tables.index.teams.indices), count: 3, rng: &rng)
            let decades = sample(tables.decades, count: 3, rng: &rng)
            guard teams.count == 3, decades.count == 3 else { return nil }
            return (teams.map(teamAxis), decades.map(decadeAxis))
        case .teamsXTeams:
            let pool = Array(tables.teamsByProminence.prefix(Self.teamXTeamPool))
            let picked = sample(pool, count: 6, rng: &rng)
            guard picked.count == 6 else { return nil }
            return (picked.prefix(3).map(teamAxis), picked.suffix(3).map(teamAxis))
        case .teamsXStats:
            let teams = sample(Array(tables.index.teams.indices), count: 3, rng: &rng)
            let stats = sample(milestones(kind: "stat"), count: 3, rng: &rng)
            guard teams.count == 3, stats.count == 3 else { return nil }
            return (teams.map(teamAxis), stats.map(milestoneAxis))
        case .teamsXMixed:
            let teams = sample(Array(tables.index.teams.indices), count: 3, rng: &rng)
            let cols = sample(mixedPool, count: 3, rng: &rng)
            guard teams.count == 3, cols.count == 3 else { return nil }
            return (teams.map(teamAxis), cols)
        case .mixedXTeams:
            let rows = sample(mixedAnyPool, count: 3, rng: &rng)
            let cols = sample(Array(tables.teamsByProminence.prefix(Self.teamXTeamPool)),
                              count: 3, rng: &rng)
            guard rows.count == 3, cols.count == 3 else { return nil }
            // `mixed_any` has to actually be mixed: an all-team draw is just teams-x-teams
            // wearing a different label, which is the sameness this shape exists to break.
            // Two distinct kinds is the floor, matching `grid.py`'s `_is_varied`.
            guard Set(rows.map { $0.axis.kind }).count >= 2 else { return nil }
            return (rows, cols.map(teamAxis))
        }
    }

    /// A team axis carries no grain, unlike grid.py's — `GridPuzzle.GridAxis` has no field for
    /// one, and it needs none: the archetype fixes the grain for both dimensions, and `answers`
    /// is the only thing that ever asks (`teamPlayers` = career, `teamDecadePlayers` = season).
    private func teamAxis(_ index: Int) -> LocalAxis {
        let team = tables.index.teams[index]
        return LocalAxis(
            axis: GridPuzzle.GridAxis(kind: .team, label: qualifiedLabel(team),
                                      abbr: team.abbr, league: team.league),
            key: team.league.isEmpty ? "team:\(team.abbr)" : "team:\(team.abbr)@\(team.league)",
            team: index, decade: nil)
    }

    private func decadeAxis(_ decade: Int) -> LocalAxis {
        LocalAxis(axis: GridPuzzle.GridAxis(kind: .decade, label: "\(decade)s"),
                  key: "decade:\(decade)", decade: decade)
    }

    /// A stat or position axis. Both label and key come straight off the payload — they were
    /// produced by `grid_axes` server-side, so a locally-generated board's combo identity and its
    /// rendered text match a server board's exactly rather than being reconstructed here.
    private func milestoneAxis(_ index: Int) -> LocalAxis {
        let axis = tables.index.axes[index]
        return LocalAxis(axis: GridPuzzle.GridAxis(kind: axis.kind == "position" ? .position : .stat,
                                                   label: axis.label),
                         key: axis.key, milestone: index)
    }

    /// "MCI-ENG" / "TOR-ITA" for a league-scoped club, the bare abbreviation otherwise — the same
    /// label `grid_axes.qualified_team_label` produces. Scoping alone fixes the *answer set* but
    /// leaves two axes both reading "MCI": correct underneath, indistinguishable on screen.
    private func qualifiedLabel(_ team: GridMembershipIndex.Team) -> String {
        guard !team.league.isEmpty else { return team.abbr }
        let code = leagueCode(team.league)
        return code.isEmpty ? team.abbr : "\(team.abbr)-\(code)"
    }

    /// Nation code for a league label — "England" → "ENG". Derived from the competition slug the
    /// `leagues` catalog already stores (`eng.1` → `ENG`), which is exactly what
    /// `grid_axes.league_code` derives it from, rather than a second hand-written map. Falls back
    /// to the label's first three alphanumerics when the identity index hasn't been warmed or the
    /// league is new, matching the Python fallback.
    static func nationCode(_ league: String) -> String {
        guard !league.isEmpty else { return "" }
        if let slug = TeamIdentityIndex.shared.leagueIdentity(sport: .soccer, league: league)?
            .competition, let head = slug.split(separator: ".").first {
            return head.uppercased()
        }
        return String(league.filter(\.isLetter).prefix(3)).uppercased()
    }

    /// Partial Fisher-Yates. `next() % k` rather than `shuffled(using:)`/`randomElement(using:)`
    /// for the reason `DraftSpin.spinRound` documents — those are measurably biased under
    /// `SeededGenerator`.
    private func sample<T>(_ pool: [T], count: Int, rng: inout SeededGenerator) -> [T] {
        guard pool.count >= count else { return [] }
        var working = pool
        var out: [T] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let j = i + Int(rng.next() % UInt64(working.count - i))
            working.swapAt(i, j)
            out.append(working[i])
        }
        return out
    }

    // MARK: - Cells

    /// All nine cells, or nil the moment one has no valid answer — the same all-or-nothing
    /// viability gate grid.py applies, and the reason a board is never shipped half-broken.
    private func cells(archetype: Archetype, rows: [LocalAxis], cols: [LocalAxis]) -> [GridPuzzle.GridCell]? {
        var out: [GridPuzzle.GridCell] = []
        out.reserveCapacity(9)
        for row in rows {
            for col in cols {
                let players = answers(archetype: archetype, row: row, col: col)
                if players.isEmpty || players.count > Self.maxCellAnswers { return nil }
                let names = players.map { tables.index.players[$0] }.sorted()
                out.append(GridPuzzle.GridCell(validAnswerIds: names.map(Self.answerSlug),
                                               validAnswerNames: names,
                                               rarityStars: Self.rarityStars(names.count)))
            }
        }
        return out
    }

    private func answers(archetype: Archetype, row: LocalAxis, col: LocalAxis) -> Set<Int> {
        switch archetype {
        case .teamsXDecades:
            guard let team = row.team, let decade = col.decade else { return [] }
            return tables.teamDecadePlayers[.init(team: team, decade: decade)] ?? []
        case .teamsXTeams:
            guard let a = row.team, let b = col.team else { return [] }
            return tables.teamPlayers[a].intersection(tables.teamPlayers[b])
        case .teamsXStats, .teamsXMixed:
            // Season grain on BOTH sides: one season has to satisfy the team and the milestone
            // together ("1,000 yards *as a Bear*"). `axisTeamPlayers` is precomputed per
            // (milestone, team) for exactly this — intersecting career sets would silently answer
            // the easier "did both, ever".
            guard let team = row.team else { return [] }
            if let decade = col.decade {
                return tables.teamDecadePlayers[.init(team: team, decade: decade)] ?? []
            }
            guard let milestone = col.milestone else { return [] }
            return tables.axisTeamPlayers[.init(axis: milestone, team: team)] ?? []
        case .mixedXTeams:
            // The column is career grain, so whatever the row is, it is the cell's ONLY
            // season-grain constraint — which reduces the grain rule to "some season satisfied
            // it" and makes a plain set intersection correct here (and only here).
            guard let team = col.team else { return [] }
            let opposite = tables.teamPlayers[team]
            if let rowTeam = row.team { return tables.teamPlayers[rowTeam].intersection(opposite) }
            if let decade = row.decade {
                return (tables.decadePlayers[decade] ?? []).intersection(opposite)
            }
            guard let milestone = row.milestone else { return [] }
            return tables.axisPlayers[milestone].intersection(opposite)
        }
    }

    /// 1 (common, 15+ valid answers) … 5 (rarest, exactly 1). `grid.py`'s `_rarity_stars`,
    /// boundary for boundary.
    static func rarityStars(_ count: Int) -> Int {
        switch count {
        case ...1: return 5
        case ...3: return 4
        case ...7: return 3
        case ...14: return 2
        default: return 1
        }
    }

    /// Mirrors `tools/ingest/models.slug` so a locally-generated board's content has the same
    /// shape as a server-minted one. Nothing in the app reads `validAnswerIds` today; emitting a
    /// real slug rather than a placeholder keeps that true if something starts to.
    static func answerSlug(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
