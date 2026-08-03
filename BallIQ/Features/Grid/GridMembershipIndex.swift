import Foundation

/// The membership relation — player → (team, league, year) — for one sport, as served by the
/// `grid_membership_index` RPC (supabase/migrations/0011). This is the entire input the client
/// needs to generate its own Grid boards: `GridLocalGenerator` turns it into boards offline,
/// instantly, and without a round trip per board.
///
/// **Why this is small enough to ship.** Measured live 2026-07-27, gzipped on the wire exactly as
/// `URLSession` receives it: nfl 69.0 KB, nba 61.5 KB, baseball 119.0 KB, soccer 254.4 KB,
/// tennis 15.8 KB. For scale: a *single* server-minted NFL board's `content` averages 64 KB
/// (cells carry 149–425 answer names), so the whole NFL index costs about what one board does,
/// and then generates an unbounded number of them. It is cached on disk for a week, the same
/// pattern `playerNameIndex` already uses.
///
/// **It leaks nothing new.** Board content already embeds every valid answer for all nine cells;
/// this is the same population, minus the stats.
struct GridMembershipIndex: Codable, Equatable {
    let sport: Sport
    /// Wire-format version. A future generator may add fields; an older client that doesn't know
    /// them must not try to use the payload (see `isUsable`).
    let version: Int
    /// Year offsets in `memberships` are relative to this, which keeps them 1–3 digits.
    let minYear: Int
    /// Index = team id used by `memberships`.
    let teams: [Team]
    /// Index = player id used by `memberships`.
    let players: [String]
    /// Parallel to `players`. One line per player:
    /// `teamIdx:yearOffset[,yearOffset…][;teamIdx:yearOffset…]`.
    let memberships: [String]
    /// Stat and position axes this sport can offer (v2+). Index = the axis id `axisMemberships`
    /// uses. Empty on a v1 payload, and empty is a legitimate answer — a sport whose catalog
    /// satisfies no axis simply offers no stat-flavoured board.
    var axes: [Axis] = []
    /// Parallel to `players`. Which axes this player ever satisfied, in any season:
    /// `axisIdx[,axisIdx…]`. **Career grain** — the reduced form of "some season satisfied it",
    /// which is all a cell needs when the axis is its only season-grain constraint.
    ///
    /// Genuinely sparse, unlike `memberships`: a player clearing no milestone is normal rather
    /// than missing data, so the server emits `""` for them instead of dropping the slot and
    /// desynchronising the index.
    var axisMemberships: [String] = []
    /// Parallel to `players`. Which (axis, team) pairs **one single season** satisfied:
    /// `axisIdx:teamIdx[,teamIdx…][;axisIdx:…]`. **Season grain**, and the reason it ships at all.
    ///
    /// This cannot be derived on-device by intersecting the two relations above. `player_seasons`
    /// is game-grain and carries teamless season-aggregate rows for mid-season movers, so
    /// "played for CLE in 2026" and "cleared 8 APG in 2026" can both be true of a player via
    /// *different rows* — which is not the same claim as "cleared 8 APG as a Cavalier", and
    /// `grid.py` says so. The pairing has to come from the row that satisfied both.
    var axisTeams: [String] = []

    /// A franchise's identity. `league` is not decoration: soccer `team_abbr` values are derived
    /// from club names and collide across countries (MCI is Manchester City *and* Melbourne
    /// City), so for soccer the identity is the pair and the RPC drops rows with a blank league.
    /// Every other sport carries `league: ""` so one franchise can't split into several teams.
    struct Team: Codable, Equatable, Hashable {
        let abbr: String
        let league: String
    }

    /// A non-team, non-decade axis — a statistical milestone or a position. Teams and decades are
    /// absent by design: both are derivable from `memberships` alone, so shipping them would be
    /// payload restating what the client can already compute.
    struct Axis: Codable, Equatable, Hashable {
        /// `grid_axes`' own key ("stat:passing_tds:gte:30"), so a locally-generated board's combo
        /// identity means the same thing as a server board's in `grid_history` terms.
        let key: String
        /// "stat" | "position" — what the axis *is*, which is also how the client renders it
        /// (everything non-team draws as a text label, so this is currently informational).
        let kind: String
        /// What appears on the board: "30+ Pass TD", "Guards".
        let label: String
    }

    /// Bumped to 2 when stat/position axes joined the payload. The RPC keeps emitting v1 to
    /// callers that don't ask for 2, which is what stops an older build — whose `isUsable`
    /// rejects any version it doesn't know — from silently losing on-device generation and
    /// falling back to the small server pool.
    static let currentVersion = 2

    /// Versions this build can actually drive generation from. v1 is still perfectly usable; it
    /// just can't offer the stat-flavoured archetypes, exactly as this client behaved before v2
    /// existed. Accepting it means a cached v1 payload from a previous build keeps working
    /// instead of forcing a refetch on first launch after upgrade.
    static let supportedVersions: ClosedRange<Int> = 1...2

    /// Whether this payload can actually drive generation. A sport with no catalog rows returns
    /// empty arrays rather than an error (the RPC coalesces), and that is indistinguishable from
    /// a failed fetch as far as the caller is concerned — both mean "fall back to the server pool".
    var isUsable: Bool {
        Self.supportedVersions.contains(version) && !players.isEmpty && teams.count >= 3
            && memberships.count == players.count
            // A v2 payload that lost its axis alignment is worse than a v1 one: every lookup
            // would silently read another player's milestones. Degrade to no axes, not to wrong.
            && (axisMemberships.isEmpty || axisMemberships.count == players.count)
            && (axisTeams.isEmpty || axisTeams.count == players.count)
    }

    /// Whether the stat/position archetypes can be offered at all. Both arrays are required:
    /// `axisTeams` alone drives the season-grain shapes and `axisMemberships` the career-grain
    /// one, so a payload carrying only one of them would half-enable the rotation.
    var hasAxes: Bool {
        !axes.isEmpty && axisMemberships.count == players.count
            && axisTeams.count == players.count
    }

    // MARK: - Decoding

    /// Written out by hand purely so `axes`/`axisMemberships` may be absent.
    ///
    /// Swift's *synthesized* `Decodable` does not fall back to a property's default value when a
    /// key is missing — it throws `keyNotFound`. So `var axes: [Axis] = []` reads like it makes
    /// the field optional on the wire, and doesn't: a v1 payload (which has no `axes` at all)
    /// failed to decode outright, taking the whole index with it. That silently contradicted
    /// `supportedVersions = 1...2` and `isUsable`'s v1 branch, which both promise a v1 payload
    /// still drives generation — and it's why every GridCrossCheckTests case failed on a v1
    /// fixture with `keyNotFound("axes")`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sport = try c.decode(Sport.self, forKey: .sport)
        version = try c.decode(Int.self, forKey: .version)
        minYear = try c.decode(Int.self, forKey: .minYear)
        teams = try c.decode([Team].self, forKey: .teams)
        players = try c.decode([String].self, forKey: .players)
        memberships = try c.decode([String].self, forKey: .memberships)
        axes = try c.decodeIfPresent([Axis].self, forKey: .axes) ?? []
        axisMemberships = try c.decodeIfPresent([String].self, forKey: .axisMemberships) ?? []
        axisTeams = try c.decodeIfPresent([String].self, forKey: .axisTeams) ?? []
    }

    /// Memberwise init, restored — declaring `init(from:)` suppresses the synthesized one, and
    /// the generator/tests build indexes directly.
    init(sport: Sport, version: Int, minYear: Int, teams: [Team], players: [String],
         memberships: [String], axes: [Axis] = [], axisMemberships: [String] = []) {
        self.sport = sport
        self.version = version
        self.minYear = minYear
        self.teams = teams
        self.players = players
        self.memberships = memberships
        self.axes = axes
        self.axisMemberships = axisMemberships
    }
}

// MARK: - Parsed lookup tables

/// `GridMembershipIndex` decoded into the two set-lookups board generation actually asks for.
/// Built once per fetched index and reused across every board, because the cost that matters is
/// per-generation, not per-fetch: a re-roll must feel instant.
///
/// The two grains here are the same distinction `tools/ingest/grid_axes.py` documents, and
/// getting it wrong is the difference between a correct board and one that rejects real answers:
///
///   * **season grain** (`teamDecadePlayers`) — one season must satisfy *both* axes. "Played for
///     the Bears in the 1990s" is a single row of a career.
///   * **career grain** (`teamPlayers`) — any season in the player's history may satisfy it.
///     "Played for both clubs" is inherently career-level; two season-grain team axes could never
///     be co-satisfied, since one season row has exactly one team.
struct GridMembershipTables {
    let index: GridMembershipIndex
    /// teamIdx → every player who ever appeared for it (career grain).
    let teamPlayers: [Set<Int>]
    /// (teamIdx, decade) → players with a season for that team in that decade (season grain).
    let teamDecadePlayers: [TeamDecade: Set<Int>]
    /// Every decade the catalog actually covers, ascending.
    let decades: [Int]
    /// (axisIdx, teamIdx) → players who satisfied the axis in a season played for that team.
    /// Read straight off `axisTeams`, never intersected on demand: `teamPlayers ∩ axisPlayers`
    /// is the *career* question ("cleared it ever, and played here ever"), a different and much
    /// easier cell than the season-grain one every stat archetype actually asks.
    let axisTeamPlayers: [AxisTeam: Set<Int>]
    /// axisIdx → every player who ever satisfied it, any season. Used where the axis is the cell's
    /// ONLY season-grain constraint (inside `mixed-x-teams`, facing a career-grain team): the
    /// grain rule then reduces to "some season satisfied it", which is exactly this set.
    let axisPlayers: [Set<Int>]
    /// decade → every player with a season in it, any team. Same role as `axisPlayers` for the
    /// decade axes that `mixed_any` can draw.
    let decadePlayers: [Int: Set<Int>]
    /// Team indices ordered by distinct player count, most first, ties broken by team index so
    /// the order is deterministic rather than dictionary-order dependent.
    ///
    /// Mirrors `grid.py`'s `_prominent_teams`, and for the same reason: two clubs drawn at random
    /// out of soccer's 676 almost never share a player, so an unrestricted team × team draw burns
    /// every attempt on unviable boards. Capping to the most-represented franchises makes the
    /// pairing both viable and recognisable.
    let teamsByProminence: [Int]

    struct TeamDecade: Hashable {
        let team: Int
        let decade: Int
    }
    struct AxisTeam: Hashable {
        let axis: Int
        let team: Int
    }

    /// Parses one `slot:value[,value…][;slot:…]` line. `memberships` and `axisTeams` share the
    /// grammar against different index spaces — years-since-`minYear` for the first, team ids for
    /// the second (pass `minYear: 0`) — so they share one parser rather than keeping two copies
    /// of the same splitting for the offset arithmetic to drift between.
    private static func runs(_ line: String, minYear: Int,
                             body: (_ slot: Int, _ value: Int) -> Void) {
        guard !line.isEmpty else { return }
        for run in line.split(separator: ";") {
            // "3:12,13" — slot index, then that slot's year offsets.
            guard let colon = run.firstIndex(of: ":"),
                  let slot = Int(run[run.startIndex..<colon]), slot >= 0 else { continue }
            for offset in run[run.index(after: colon)...].split(separator: ",") {
                guard let delta = Int(offset) else { continue }
                body(slot, minYear + delta)
            }
        }
    }

    init(_ index: GridMembershipIndex) {
        self.index = index
        var career = [Set<Int>](repeating: [], count: index.teams.count)
        var seasonal: [TeamDecade: Set<Int>] = [:]
        var decadeSet: Set<Int> = []
        // (player, year) → the teams played that year, so axis membership can be joined back onto
        // a team within the SAME season. Without it a stat axis could only be crossed with a team
        // at career grain, which is a different (and far easier) question than "1,000 yards *as a
        // Bear*" — the exact distinction `grid_axes` calls load-bearing.
        var byDecade: [Int: Set<Int>] = [:]

        for (playerIdx, line) in index.memberships.enumerated() {
            Self.runs(line, minYear: index.minYear) { teamIdx, year in
                guard teamIdx < career.count else { return }
                career[teamIdx].insert(playerIdx)
                let decade = (year / 10) * 10
                decadeSet.insert(decade)
                byDecade[decade, default: []].insert(playerIdx)
                seasonal[TeamDecade(team: teamIdx, decade: decade), default: []].insert(playerIdx)
            }
        }

        var axisTeam: [AxisTeam: Set<Int>] = [:]
        var axisAny = [Set<Int>](repeating: [], count: index.axes.count)
        if index.hasAxes {
            for (playerIdx, line) in index.axisMemberships.enumerated() where !line.isEmpty {
                for field in line.split(separator: ",") {
                    guard let axisIdx = Int(field), axisIdx >= 0, axisIdx < axisAny.count
                    else { continue }
                    axisAny[axisIdx].insert(playerIdx)
                }
            }
            // Same `slot:values` grammar as `memberships`, but the values are team ids rather
            // than years — the pairing is already resolved server-side, so there is nothing to
            // join here and no opportunity to join it wrongly.
            for (playerIdx, line) in index.axisTeams.enumerated() {
                Self.runs(line, minYear: 0) { axisIdx, teamIdx in
                    guard axisIdx < axisAny.count, teamIdx < career.count else { return }
                    axisTeam[AxisTeam(axis: axisIdx, team: teamIdx), default: []].insert(playerIdx)
                }
            }
        }

        self.teamPlayers = career
        self.teamDecadePlayers = seasonal
        self.axisTeamPlayers = axisTeam
        self.axisPlayers = axisAny
        self.decadePlayers = byDecade
        self.decades = decadeSet.sorted()
        self.teamsByProminence = career.indices.sorted {
            career[$0].count != career[$1].count ? career[$0].count > career[$1].count : $0 < $1
        }
    }
}
