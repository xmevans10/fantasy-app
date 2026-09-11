import SwiftUI

enum Sport: String, Codable, CaseIterable, Identifiable {
    case nfl
    case nba
    case baseball
    case soccer
    case tennis
    case hockey
    case f1

    var id: String { rawValue }

    /// A PostgREST `in.(…)` value naming every sport THIS BUILD can decode.
    ///
    /// The archive fetch used to send no sport predicate at all on the "All" filter, and that is
    /// the whole mechanism behind the release problem `validate.WIRE_SAFE_SPORTS` exists to hold
    /// back: `Sport` is a plain `String` raw-value enum with no unknown case, the pool is decoded
    /// as one ARRAY under `try?`, and a single row naming a sport this build has never heard of
    /// throws and nils the entire array. Not that row — all of them. The player's archive then
    /// silently falls back to stale cache or the bundled JSON, with nothing logged anywhere they
    /// or we can see it.
    ///
    /// Sending this instead makes a client **self-protecting**: it asks for the sports it knows,
    /// so publishing a new one cannot reach it at all, and the ingest gate stops being the only
    /// thing standing between a new sport and every installed build. What it cannot do is repair
    /// builds already in the wild — they still send no predicate — so opening the gate remains a
    /// support-floor decision, and this is the version that floor has to name.
    static var decodableFilterValue: String {
        "in.(\(allCases.map(\.rawValue).joined(separator: ",")))"
    }

    var displayName: String {
        switch self {
        case .nfl: return "NFL"
        case .nba: return "NBA"
        case .baseball: return "MLB"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        case .hockey: return "NHL"
        case .f1: return "F1"
        }
    }

    var abbreviation: String { displayName }

    /// Whether this sport's careers are a **club history** at all — the precondition for
    /// Journeyman, whose entire board is "which clubs, in which order".
    ///
    /// False for tennis, and permanently: a tour player has a nationality, not a club, so there
    /// is no path to draw. This is a category fact about the sport, **not** a content gap waiting
    /// on a backfill, and it mirrors the pipeline's own source of truth —
    /// `tools/ingest/journeyman.py`'s `MIN_STINTS` is keyed `{nfl, nba, baseball, soccer}` and has
    /// never had a tennis entry. Live pool counts agree (2026-08-25): 158 NFL / 150 NBA / 158 MLB
    /// / 87 soccer boards, and 0 tennis.
    ///
    /// Declared here rather than inferred from an empty fetch because the two mean different
    /// things: an empty fetch is "nothing right now" (retry, or wait for the mint), while this is
    /// "never". Only the second one justifies hiding the format from a picker.
    var hasClubCareers: Bool { self != .tennis }

    /// SF Symbol used in filter pills / format icons.
    var symbol: String {
        switch self {
        case .nfl: return "football.fill"
        case .nba: return "basketball.fill"
        case .baseball: return "baseball.fill"
        case .soccer: return "soccerball"
        case .tennis: return "tennisball.fill"
        case .hockey: return "hockey.puck.fill"
        // F1 has no car/circuit symbol in SF Symbols; the checkered flag is the sport's
        // most-recognized mark and is the same visual family (a filled glyph) as the balls.
        case .f1: return "flag.checkered"
        }
    }

    /// Header-band fill for puzzle cards — cards are colored by sport (not puzzle type), so a
    /// user can tell "this is an NBA puzzle" at a glance across Keep4/Who Am I/Community.
    /// Puzzle type gets its own chip instead (see `DailyGameCard`'s `typeColor`).
    var cardFill: Color {
        switch self {
        case .nfl: return .sportNFLFill
        case .nba: return .sportNBAFill
        case .baseball: return .sportMLBFill
        case .soccer: return .sportSoccerFill
        case .tennis: return .sportTennisFill
        case .hockey: return .sportHockeyFill
        case .f1: return .sportF1Fill
        }
    }

    /// Foreground color for text/icons drawn on `cardFill`.
    var onCardFill: Color {
        switch self {
        case .nfl: return .onSportNFL
        case .nba: return .onSportNBA
        case .baseball: return .onSportMLB
        case .soccer: return .onSportSoccer
        case .tennis: return .onSportTennis
        case .hockey: return .onSportHockey
        case .f1: return .onSportF1
        }
    }

    /// Whether `PlayerSeason.teamAbbr` names a real club/franchise for this sport. Tennis has
    /// no team — `teamAbbr` holds the player's country code instead (see `providers/seed.py`'s
    /// `load_tennis` docstring), so card UI should render a country flag in the logo slot rather
    /// than attempting a team lookup/logo fetch that can never resolve.
    var hasTeams: Bool { self != .tennis }

    /// ESPN CDN league slug used for team-logo lookups; nil for teamless sports (tennis).
    /// Each sport MUST map to its own slug — sharing one (e.g. defaulting non-NFL to "nba")
    /// silently pulls the wrong league's crest for shared city codes (MLB "HOU" → the NBA
    /// Rockets instead of the Astros).
    var espnLeagueSlug: String? {
        switch self {
        case .nfl: return "nfl"
        case .nba: return "nba"
        case .baseball: return "mlb"
        case .soccer: return "soccer"
        case .tennis: return nil
        case .hockey: return "nhl"
        // F1 constructor crests are NOT on the ESPN CDN — ESPN's own `/racing/f1/teams`
        // payload carries no `logos` array and no stable abbreviation (verified 2026-09-03),
        // and historic constructors (Brabham, Tyrrell, Lotus) were never there at all. They
        // come through the `teams` table / Storage rehost instead, so this returns nil and
        // `teamLogoURL` falls through to the fetched identity or a neutral placeholder.
        case .f1: return nil
        }
    }

    /// ESPN keys soccer crests by numeric team id, not the club abbreviation our catalog
    /// carries, so soccer abbreviations must be translated (US-league logos resolve directly
    /// from the lowercased abbreviation). Covers every club currently in the catalog.
    private static let soccerESPNTeamID: [String: String] = [
        "AVL": "362", "BAY": "132", "BUR": "379", "CHE": "363", "FCB": "83",
        "LIV": "364", "MCI": "382", "MUN": "360", "PSG": "160", "RMA": "86", "TOT": "367",
    ]

    /// Team-crest URL for `abbr` — prefers the fetched `teams.logo_url` (the real, current crest,
    /// keyed by (sport, abbr, league) since abbreviations collide across leagues/countries) over
    /// the hardcoded ESPN CDN lookup below. `league` is optional so pre-existing call sites (which
    /// never had one to give) keep compiling, just skipping straight to the ESPN path; `index`
    /// defaults to the shared production instance, with tests injecting a fresh one so they can
    /// exercise the data-driven path without touching state `SportLogoTests` depends on staying
    /// empty. Callers render a neutral fallback on nil rather than a broken image either way.
    func teamLogoURL(forAbbr abbr: String, league: String? = nil,
                     index: TeamIdentityIndex = .shared) -> URL? {
        let fetched = index.identity(sport: self, abbr: abbr, league: league)?.logoURL
        // A fetched crest that is *not* one of our own Storage objects means somebody pointed this
        // club somewhere deliberately, so it outranks a build-time snapshot. Every production row
        // is a rehosted Storage URL, so in practice this only fires for a manual override — which
        // is exactly when live data should win over the bundle.
        if let fetched, !fetched.absoluteString.contains(BundledCrests.storageMarker) { return fetched }
        if let bundled = BundledCrests.url(sport: self, abbr: abbr, league: league) { return bundled }
        return fetched ?? legacyTeamLogoURL(forAbbr: abbr)
    }

    /// The original ESPN CDN lookup — kept as the offline/pre-data fallback for `teamLogoURL`
    /// above, and as the last resort when a team simply isn't in the fetched `teams` table yet.
    private func legacyTeamLogoURL(forAbbr abbr: String) -> URL? {
        guard let league = espnLeagueSlug, !abbr.isEmpty else { return nil }
        let key: String
        if self == .soccer {
            guard let id = Sport.soccerESPNTeamID[abbr.uppercased()] else { return nil }
            key = id
        } else {
            key = abbr.lowercased()
        }
        return URL(string: "https://a.espncdn.com/i/teamlogos/\(league)/500/\(key).png")
    }

    // MARK: - Position stat families

    /// Stat-key prefixes a position actually produces, keyed by sport then position —
    /// mirrors `tools/ingest/themes.py`'s `_NFL_POSITION_STATS`, generalized to every sport
    /// with position-disjoint stats. Used to slice display columns for any cross-position
    /// pool (a daily cross-position theme, a Vibes community puzzle mixing positions, a
    /// custom scoring rule applied to a mixed pool) so a card never shows a stat family its
    /// position doesn't record — a QB's "Rec Yds", a pitcher's "AVG", a keeper's "Goals".
    /// The defensive groups (DL/LB/DB) are app-first: no shipped theme mixes defenders yet
    /// (the daily pipeline's themes are offense-only), so there is nothing in themes.py to
    /// mirror — the groups exist so Draft & Spin's Both-sides rosters and any future
    /// cross-position pool can never show a cornerback a sack line. Position codes match
    /// `nfl_nflverse_defense.py`'s granular values (see that provider's docstring — the
    /// three groups collapse ~13 raw codes). NBA, tennis and F1 are omitted: their
    /// stats (PPG/RPG/APG/…, Wins/Titles/…, Points/Wins/Podiums/Poles) apply broadly
    /// regardless of position, so there is nothing to slice — F1 in particular has exactly
    /// one position ("Driver"), the same shape as tennis's "Player".
    static let positionStatFamilies: [Sport: [String: [String]]] = [
        .nfl: [
            // `games` is on every one of these because every position plays them; `carries`/
            // `ypc` are on QB because a QB's rushing line is his, not a borrowed one. WR/TE
            // deliberately stay receiving-only even though 44% of WR seasons carry a non-zero
            // rushing line (measured over the bundled catalog): an end-around is incidental,
            // and admitting it would put a dead "Rush Yds 0" tile on the other 56%.
            "QB": ["passing_", "rushing_", "interceptions", "completions", "attempts",
                   "completion_pct", "carries", "ypc", "games"],
            "RB": ["rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr", "games"],
            "FB": ["rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr", "games"],
            "WR": ["receiving_", "receptions", "targets", "ypr", "games"],
            "TE": ["receiving_", "receptions", "targets", "ypr", "games"],
            "DE": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                   "fumble_recoveries", "def_interceptions", "passes_defended",
                   "defensive_tds", "safeties", "games"],
            "DT": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                   "fumble_recoveries", "def_interceptions", "passes_defended",
                   "defensive_tds", "safeties", "games"],
            "NT": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                   "fumble_recoveries", "def_interceptions", "passes_defended",
                   "defensive_tds", "safeties", "games"],
            "DL": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                   "fumble_recoveries", "def_interceptions", "passes_defended",
                   "defensive_tds", "safeties", "games"],
            "OLB": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                    "fumble_recoveries", "def_interceptions", "passes_defended",
                    "defensive_tds", "safeties", "games"],
            "MLB": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                    "fumble_recoveries", "def_interceptions", "passes_defended",
                    "defensive_tds", "safeties", "games"],
            "ILB": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                    "fumble_recoveries", "def_interceptions", "passes_defended",
                    "defensive_tds", "safeties", "games"],
            "LB": ["tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                   "fumble_recoveries", "def_interceptions", "passes_defended",
                   "defensive_tds", "safeties", "games"],
            "CB": ["tackles_", "def_interceptions", "passes_defended", "forced_fumbles",
                   "fumble_recoveries", "defensive_tds", "safeties", "games"],
            "FS": ["tackles_", "def_interceptions", "passes_defended", "forced_fumbles",
                   "fumble_recoveries", "defensive_tds", "safeties", "games"],
            "SS": ["tackles_", "def_interceptions", "passes_defended", "forced_fumbles",
                   "fumble_recoveries", "defensive_tds", "safeties", "games"],
            "S": ["tackles_", "def_interceptions", "passes_defended", "forced_fumbles",
                  "fumble_recoveries", "defensive_tds", "safeties", "games"],
            "SAF": ["tackles_", "def_interceptions", "passes_defended", "forced_fumbles",
                    "fumble_recoveries", "defensive_tds", "safeties", "games"],
            "DB": ["tackles_", "def_interceptions", "passes_defended", "forced_fumbles",
                   "fumble_recoveries", "defensive_tds", "safeties", "games"],
        ],
        .baseball: [
            "H": ["hits", "doubles", "triples", "home_runs", "runs", "rbi", "base_on_balls",
                  "stolen_bases", "avg", "obp", "slg", "ops", "at_bats", "plate_appearances"],
            // A pitcher's walks ALLOWED are `base_on_balls`, the same key a hitter's walks
            // drawn use. Its absence here read a "Walk-prone pitching seasons" card as showing
            // a stat pitchers don't record — the reverse of the truth.
            "P": ["innings_pitched", "wins", "losses", "saves", "strike_outs", "earned_runs",
                  "era", "whip", "base_on_balls"],
        ],
        .soccer: [
            "GK": ["clean_sheets", "appearances"],
            "DF": ["clean_sheets", "appearances", "goals", "assists"],
            "FW": ["appearances", "goals", "assists"],
            "MF": ["appearances", "goals", "assists"],
        ],
        // Hockey splits exactly like baseball's H/P: skaters and goalies are scored from two
        // disjoint stat vocabularies pulled from two different NHL endpoints
        // (`skater/summary` vs `goalie/summary` — see `providers/nhl_stats.py`), so a goalie
        // card must never read "Goals 0" and a winger's must never read "SV% 0.000".
        // Position codes are the API's own `positionCode` values.
        .hockey: [
            "C": _hockeySkaterStats, "L": _hockeySkaterStats,
            "R": _hockeySkaterStats, "D": _hockeySkaterStats,
            "G": _hockeyGoalieStats,
        ],
    ]

    /// Shared so the four skater codes can't drift apart — a centre and a winger record the
    /// same things, and the only real split in hockey is skater vs goalie.
    private static let _hockeySkaterStats = [
        "goals", "assists", "points", "plus_minus", "penalty_minutes", "shots",
        "shooting_pct", "points_per_game", "pp_points", "sh_points",
        "game_winning_goals", "toi_per_game", "games",
    ]

    private static let _hockeyGoalieStats = [
        "wins", "losses", "ot_losses", "gaa", "save_pct", "shutouts", "saves",
        "shots_against", "goals_against", "games", "games_started",
    ]

    /// Explicit default stat sheet per position — the obvious, prominent counting stats a
    /// fan would expect for that position, nothing more. Unlike `positionStatFamilies` (a
    /// membership test used to slice an arbitrary column list), this is itself the column
    /// list: free-form/Vibes community creation fills these keys in directly for a card
    /// instead of deriving an order from `ScoringStat`'s own catalog declaration order.
    /// Each list is the position's real-world "stat line" (the standard passing line for a
    /// QB, the receiving line for a WR/TE, the old-school hitting/pitching "triple crown"
    /// categories for baseball) — not a mechanical port of any one daily-pipeline theme's
    /// column count, which can include secondary/advanced stats (targets, YPR, WHIP, OPS)
    /// that overcomplicate a default card. Soccer GK gets its own narrower list than DF
    /// (clean sheets + appearances only) since goals/assists aren't an obvious keeper stat
    /// even though the daily pipeline's `soccer-defenders` theme shows all 4 to both.
    /// NBA/tennis/F1 omitted for the same reason as `positionStatFamilies` — their stats
    /// apply broadly regardless of position. Defensive groups follow the same app-first note as
    /// `positionStatFamilies`: each reads like a real IDP stat line — the sack line for a
    /// rusher (DL), the tackle line for a run-stopper (LB), the coverage line for a DB.
    static let positionStatTemplates: [Sport: [String: [String]]] = [
        .nfl: [
            "QB": ["passing_yards", "passing_tds", "interceptions", "rushing_yards", "rushing_tds",
                   "completions", "attempts", "completion_pct"],
            "RB": ["rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds", "receptions", "ypc"],
            "FB": ["rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds", "receptions", "ypc"],
            "WR": ["receiving_yards", "receptions", "receiving_tds"],
            "TE": ["receiving_yards", "receptions", "receiving_tds"],
            "DE": ["sacks", "tackles_combined", "tackles_for_loss", "qb_hits"],
            "DT": ["sacks", "tackles_combined", "tackles_for_loss", "qb_hits"],
            "NT": ["sacks", "tackles_combined", "tackles_for_loss", "qb_hits"],
            "DL": ["sacks", "tackles_combined", "tackles_for_loss", "qb_hits"],
            "OLB": ["tackles_combined", "sacks", "tackles_for_loss", "def_interceptions"],
            "MLB": ["tackles_combined", "sacks", "tackles_for_loss", "def_interceptions"],
            "ILB": ["tackles_combined", "sacks", "tackles_for_loss", "def_interceptions"],
            "LB": ["tackles_combined", "sacks", "tackles_for_loss", "def_interceptions"],
            "CB": ["tackles_combined", "def_interceptions", "passes_defended", "forced_fumbles"],
            "FS": ["tackles_combined", "def_interceptions", "passes_defended", "forced_fumbles"],
            "SS": ["tackles_combined", "def_interceptions", "passes_defended", "forced_fumbles"],
            "S": ["tackles_combined", "def_interceptions", "passes_defended", "forced_fumbles"],
            "SAF": ["tackles_combined", "def_interceptions", "passes_defended", "forced_fumbles"],
            "DB": ["tackles_combined", "def_interceptions", "passes_defended", "forced_fumbles"],
        ],
        .baseball: [
            "H": ["home_runs", "rbi", "avg"],
            "P": ["wins", "era", "strike_outs"],
        ],
        .soccer: [
            "GK": ["clean_sheets", "appearances"],
            "DF": ["clean_sheets", "appearances", "goals", "assists"],
            "FW": ["goals", "assists", "appearances"],
            "MF": ["goals", "assists", "appearances"],
        ],
        // The real hockey stat line: G-A-P for forwards (the way every scoreboard prints it),
        // and the same three plus plus-minus for defencemen, whose value a bare goal total
        // misrepresents. Goalies get the goalie line: record, GAA, SV%, shutouts.
        .hockey: [
            "C": ["goals", "assists", "points"],
            "L": ["goals", "assists", "points"],
            "R": ["goals", "assists", "points"],
            "D": ["goals", "assists", "points", "plus_minus"],
            "G": ["wins", "gaa", "save_pct", "shutouts"],
        ],
    ]

    /// Single-game overrides for `positionStatTemplates`, used only when a free-form
    /// creation pool is scoped to single-game rows (`CatalogQuery.grain == .singleGame`).
    /// NFL/soccer game rows carry the exact same stat keys as their season rows (a game's
    /// `rushing_yards` and a season's `rushing_yards` are the same field name, just a
    /// smaller number) so they need no override and fall through to the season template
    /// above. NBA and baseball differ: NBA game rows carry raw single-game totals
    /// (`points`/`rebounds`/`assists`/`blocks`) where season rows carry per-game rate
    /// stats (`ppg`/`rpg`/...) — showing "PPG" on a single-game card would read `stats["ppg"]`
    /// (absent on a game row) and silently render "0.0". Baseball game rows lack the
    /// season-only *rate* stats `avg`/`era` (not meaningful/emitted for one game — see
    /// `mlb_stats_games.py`), so those two keys are swapped for raw counting stats the
    /// game rows do carry. NBA has no entry in `positionStatTemplates` at all (its stats
    /// apply broadly regardless of position), so this is NBA's only template, season or game.
    static let positionStatTemplatesGame: [Sport: [String: [String]]] = [
        .nba: [
            "G": ["points", "assists", "rebounds"],
            "F": ["points", "rebounds", "assists"],
            "C": ["points", "rebounds", "blocks"],
        ],
        .baseball: [
            "H": ["home_runs", "rbi", "hits"],
            "P": ["strike_outs", "earned_runs", "innings_pitched"],
        ],
    ]

    /// Slice a stat-keyed sequence (theme columns, `ScoringStat`s, …) down to `position`'s
    /// families for this sport. Returns `columns` unchanged if the sport/position has no
    /// family entry, or if slicing would leave fewer than `minimum` — a too-aggressive slice
    /// reading worse than the unfiltered set.
    func sliceForPosition<T>(_ columns: [T], position: String?, minimum: Int = 3,
                             statKey: (T) -> String) -> [T] {
        guard let position, let prefixes = Sport.positionStatFamilies[self]?[position] else { return columns }
        let sliced = columns.filter { col in prefixes.contains { statKey(col).hasPrefix($0) } }
        return sliced.count >= minimum ? sliced : columns
    }

    /// Whether `position` records `stat` at all in this sport — the single-stat form of
    /// `sliceForPosition`'s membership test, and the predicate `Keep4Theme.columns(for:)`
    /// composes a card from. `true` when the sport/position has no family entry: absence
    /// means "no split to draw here" (NBA, tennis, F1), not "unknown". Mirrors
    /// `tools/ingest/themes.py`'s `produces`.
    func produces(position: String?, stat: String) -> Bool {
        guard let position, let prefixes = Sport.positionStatFamilies[self]?[position] else { return true }
        return prefixes.contains { stat.hasPrefix($0) }
    }

    /// `position`'s canonical stat-card keys at `grain` — the game override where one exists
    /// (`positionStatTemplatesGame`), else the season template, else empty for a sport with
    /// no position split. Mirrors themes.py's `POSITION_CARD` / `POSITION_CARD_GAME` lookup.
    func canonicalCard(position: String?, grain: PuzzleGrain = .season) -> [String] {
        guard let position else { return [] }
        if grain == .singleGame, let game = Sport.positionStatTemplatesGame[self]?[position] {
            return game
        }
        return Sport.positionStatTemplates[self]?[position] ?? []
    }
}

/// Home-screen sport filter — "All" plus each concrete sport.
enum SportFilter: String, CaseIterable, Identifiable {
    case all
    case nfl
    case nba
    case baseball
    case soccer
    case tennis
    case hockey
    case f1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .nfl: return "NFL"
        case .nba: return "NBA"
        case .baseball: return "MLB"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        case .hockey: return "NHL"
        case .f1: return "F1"
        }
    }

    /// Whether a puzzle of the given sport should be shown under this filter.
    func includes(_ sport: Sport) -> Bool {
        switch self {
        case .all: return true
        case .nfl: return sport == .nfl
        case .nba: return sport == .nba
        case .baseball: return sport == .baseball
        case .soccer: return sport == .soccer
        case .tennis: return sport == .tennis
        case .hockey: return sport == .hockey
        case .f1: return sport == .f1
        }
    }

    /// The concrete sport this filter pins to, or nil for `.all`.
    var sport: Sport? {
        switch self {
        case .all: return nil
        case .nfl: return .nfl
        case .nba: return .nba
        case .baseball: return .baseball
        case .soccer: return .soccer
        case .tennis: return .tennis
        case .hockey: return .hockey
        case .f1: return .f1
        }
    }
}
