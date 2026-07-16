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
    /// Pre-formatted display date (e.g. "Apr 8") for non-NFL single-game rows, where a
    /// "Wk W" label doesn't make sense — see assemble.py's `_player_content`. nil for NFL
    /// game rows (they use `week`) and season/career cards.
    var gameDate: String? = nil
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
        if let gameDate, let opponent {
            return "vs \(opponent) · \(gameDate) · \(seasonYear)"
        }
        if let week, let opponent {
            return "vs \(opponent) · Wk \(week) · \(seasonYear)"
        }
        if let firstYear, let lastYear {
            return lastYear != firstYear ? "\(teamAbbr) · \(firstYear)-\(lastYear)" : "\(teamAbbr) · \(firstYear)"
        }
        return "\(teamAbbr) · \(seasonYear)"
    }

    /// The revealed grade, shown at the formula's full 1-decimal precision with grouping
    /// ("4,713.8", "435.7") — the tenths digit is real scoring signal, so the reveal
    /// never rounds it away.
    var gradeText: String {
        let tenths = Int((grade * 10).rounded())
        return "\(Keep4Theme.commaGrouped(tenths / 10)).\(abs(tenths % 10))"
    }
}
