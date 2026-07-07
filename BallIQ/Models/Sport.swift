import SwiftUI

enum Sport: String, Codable, CaseIterable, Identifiable {
    case nfl
    case nba
    case baseball
    case soccer
    case tennis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nfl: return "NFL"
        case .nba: return "NBA"
        case .baseball: return "MLB"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        }
    }

    var abbreviation: String { displayName }

    /// SF Symbol used in filter pills / format icons.
    var symbol: String {
        switch self {
        case .nfl: return "football.fill"
        case .nba: return "basketball.fill"
        case .baseball: return "baseball.fill"
        case .soccer: return "soccerball"
        case .tennis: return "tennisball.fill"
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
        }
    }

    /// ESPN keys soccer crests by numeric team id, not the club abbreviation our catalog
    /// carries, so soccer abbreviations must be translated (US-league logos resolve directly
    /// from the lowercased abbreviation). Covers every club currently in the catalog.
    private static let soccerESPNTeamID: [String: String] = [
        "AVL": "362", "BAY": "132", "BUR": "379", "CHE": "363", "FCB": "83",
        "LIV": "364", "MCI": "382", "MUN": "360", "PSG": "160", "RMA": "86", "TOT": "367",
    ]

    /// Team-crest URL on the ESPN CDN for a club abbreviation, or nil when the sport is
    /// teamless, the abbreviation is empty, or (soccer only) the club isn't mapped. Callers
    /// render a neutral fallback on nil rather than a broken image.
    func teamLogoURL(forAbbr abbr: String) -> URL? {
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
    /// NBA and tennis are omitted: their stats (PPG/RPG/APG/…, Wins/Titles/…) apply broadly
    /// regardless of position, so there's nothing to slice.
    static let positionStatFamilies: [Sport: [String: [String]]] = [
        .nfl: [
            "QB": ["passing_", "rushing_", "interceptions", "completions", "attempts", "completion_pct"],
            "RB": ["rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr"],
            "FB": ["rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr"],
            "WR": ["receiving_", "receptions", "targets", "ypr"],
            "TE": ["receiving_", "receptions", "targets", "ypr"],
        ],
        .baseball: [
            "H": ["hits", "doubles", "triples", "home_runs", "runs", "rbi", "base_on_balls",
                  "stolen_bases", "avg", "obp", "slg", "ops"],
            "P": ["innings_pitched", "wins", "saves", "strike_outs", "earned_runs", "era", "whip"],
        ],
        .soccer: [
            "GK": ["clean_sheets", "appearances"],
            "DF": ["clean_sheets", "appearances", "goals", "assists"],
            "FW": ["appearances", "goals", "assists"],
            "MF": ["appearances", "goals", "assists"],
        ],
    ]

    /// Explicit default stat sheet per position — the headline counting stats a fan would
    /// expect for that position, in display order. Unlike `positionStatFamilies` (a
    /// membership test used to slice an arbitrary column list), this is itself the column
    /// list: free-form/Vibes community creation fills these keys in directly for a card
    /// instead of deriving an order from `ScoringStat`'s own catalog declaration order. Runs
    /// longer than 3 for positions where that's the natural stat line (QB, RB) — Keep4CardView's
    /// stat grid wraps a fuller line. NBA/tennis omitted for the same reason as
    /// `positionStatFamilies` — their stats apply broadly regardless of position.
    static let positionStatTemplates: [Sport: [String: [String]]] = [
        .nfl: [
            "QB": ["passing_yards", "passing_tds", "rushing_yards", "rushing_tds",
                   "completions", "attempts", "completion_pct"],
            "RB": ["rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds", "ypc"],
            "FB": ["rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds", "ypc"],
            "WR": ["receiving_yards", "receiving_tds", "receptions", "targets", "ypr"],
            "TE": ["receiving_yards", "receiving_tds", "receptions", "targets", "ypr"],
        ],
        .baseball: [
            "H": ["home_runs", "rbi", "avg", "hits", "runs"],
            "P": ["wins", "era", "strike_outs", "whip", "innings_pitched"],
        ],
        .soccer: [
            "GK": ["clean_sheets", "appearances"],
            "DF": ["clean_sheets", "appearances", "goals", "assists"],
            "FW": ["goals", "assists", "appearances"],
            "MF": ["goals", "assists", "appearances"],
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
}

/// Home-screen sport filter — "All" plus each concrete sport.
enum SportFilter: String, CaseIterable, Identifiable {
    case all
    case nfl
    case nba
    case baseball
    case soccer
    case tennis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .nfl: return "NFL"
        case .nba: return "NBA"
        case .baseball: return "MLB"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
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
        }
    }
}
