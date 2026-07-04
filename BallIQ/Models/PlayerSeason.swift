import Foundation

/// A single player-season "card" in a Keep4/Cut4 puzzle.
struct PlayerSeason: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let teamAbbr: String
    let seasonYear: Int
    /// Display stat lines, ordered. e.g. [("Rec Yds", "1,632"), ("TD", "17")].
    let stats: [StatLine]
    /// Hidden quality grade used to derive the true ranking. Higher = better.
    let grade: Double
    /// Optional player headshot URL (nflverse / ESPN); nil for older/seed seasons. Additive +
    /// optional so existing baked content (no key) decodes unchanged.
    var headshot: String? = nil
    /// Single-game grain (nil for season cards). Both set together — see assemble.py
    /// `_player_content`. Additive + optional so season-only content decodes unchanged.
    var week: Int? = nil
    var opponent: String? = nil
    /// Career grain (nil for season/single-game cards). Both set together — see
    /// assemble.py `_player_content`; `seasonYear` holds the player's LAST season for
    /// this row, `firstYear`/`lastYear` give the full span for display.
    var firstYear: Int? = nil
    var lastYear: Int? = nil

    struct StatLine: Codable, Equatable, Hashable {
        let label: String
        let value: String
    }

    var subtitle: String {
        if let week, let opponent {
            return "vs \(opponent) · Wk \(week) · \(seasonYear)"
        }
        if let firstYear, let lastYear {
            return lastYear != firstYear ? "\(teamAbbr) · \(firstYear)-\(lastYear)" : "\(teamAbbr) · \(firstYear)"
        }
        return "\(teamAbbr) · \(seasonYear)"
    }
}
