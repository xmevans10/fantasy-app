import Foundation

/// The Grid (M5 Phase E, Pro-only): a 3x3 team x decade board, generated server-side by
/// `tools/ingest/grid.py` with a viability guarantee (every cell has >=1 real answer). Content
/// shape mirrors `grid.to_content(...)`'s camelCase JSON exactly.
struct GridPuzzle: Codable, Equatable, SportScoped {
    let sport: Sport
    let rowTeams: [String]
    let colDecades: [Int]
    let cells: [GridCell]

    struct GridCell: Codable, Equatable {
        let validAnswerIds: [String]
        let validAnswerNames: [String]
        let rarityStars: Int
    }

    func cell(row: Int, col: Int) -> GridCell { cells[row * 3 + col] }

    /// Whether `guess` matches one of this cell's valid answers — same tolerant matching
    /// (case-insensitive, last-name-only, single-typo) WhoAmI already uses, reused rather
    /// than reinventing a second free-text matcher. No aliases here (Grid's content only
    /// carries canonical names), so each candidate is wrapped as its own bare `AcceptedAnswer`.
    func isCorrect(row: Int, col: Int, guess: String) -> Bool {
        let candidates = cell(row: row, col: col).validAnswerNames
        return candidates.contains {
            AnswerMatcher.matches(guess, answer: .init(canonical: $0, aliases: []))
        }
    }
}
