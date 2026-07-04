import Foundation

/// Client-side text search over puzzle titles and player names (M13). Pure, like
/// `BrowseFilters` — total content volume is in the hundreds, so filtering the
/// already-loaded list beats a server query path (revisit if that changes).
enum PuzzleSearch {
    /// Lowercased, diacritic-folded ("Amar'e" matches "amare"), for both sides of a match.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }

    /// Whether `query` hits any of `candidates`: every whitespace token of the query must
    /// prefix-match some word in a single candidate string ("cee lam" → "CeeDee Lamb").
    /// Words are considered both split on punctuation and with punctuation stripped, so
    /// "amare" finds "Amar'e" and "obj" finds "O.B.J.". An empty query matches everything.
    static func matches(query: String, in candidates: [String]) -> Bool {
        let tokens = normalized(query).split(separator: " ")
        guard !tokens.isEmpty else { return true }
        return candidates.contains { candidate in
            let folded = normalized(candidate)
            var words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            words += folded
                .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
                .split(whereSeparator: \.isWhitespace)
            return tokens.allSatisfy { token in
                words.contains { $0.hasPrefix(token) }
            }
        }
    }

    /// Keep4 archive search: theme title or any player name.
    static func matches(query: String, keep4 puzzle: Keep4Puzzle) -> Bool {
        matches(query: query, in: [puzzle.theme] + puzzle.players.map(\.name))
    }

    /// Community feed search: title + author's note. Player names aren't in the feed
    /// summary (content loads on play), and Who Am I? answers must never be searchable.
    static func matches(query: String, community item: CommunitySummary) -> Bool {
        matches(query: query, in: [item.title, item.description ?? ""])
    }
}
