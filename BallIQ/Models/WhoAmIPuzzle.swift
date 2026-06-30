import Foundation

/// A daily "Who Am I?" puzzle: identify a mystery player from progressively revealed clues.
struct WhoAmIPuzzle: Identifiable, Codable, Equatable {
    let id: String
    let sport: Sport
    let clues: [Clue]            // ordered, 6 per the brief
    let answer: AcceptedAnswer

    struct Clue: Codable, Equatable, Identifiable {
        let order: Int
        let kind: ClueKind
        let text: String
        var id: Int { order }
    }

    struct AcceptedAnswer: Codable, Equatable {
        let canonical: String
        let aliases: [String]
    }
}

enum ClueKind: String, Codable {
    case era, position, teams, statLine, fact, jersey

    /// Sentence-case label (CDS).
    var label: String {
        switch self {
        case .era: return "Era"
        case .position: return "Position"
        case .teams: return "Teams"
        case .statLine: return "Stat line"
        case .fact: return "Known for"
        case .jersey: return "Jersey"
        }
    }
}

/// Pure scoring for Who Am I? — earlier solve = more points; wrong guesses cost points.
enum WhoAmIScoring {
    static let perClue = [1000, 800, 600, 400, 200, 100]
    static let wrongPenalty = -100

    struct Result: Equatable {
        let cluesUsed: Int      // 1...6
        let wrongGuesses: Int
        let solved: Bool
        let total: Int
        /// Normalized 0...1 for the rating engine (clue efficiency; 0 if unsolved).
        let performance: Double
    }

    static func score(cluesUsed: Int, wrongGuesses: Int, solved: Bool) -> Result {
        let idx = min(max(cluesUsed - 1, 0), perClue.count - 1)
        let base = solved ? perClue[idx] : 0
        let total = max(0, base + wrongGuesses * wrongPenalty)
        let performance = solved ? Double(perClue[idx]) / Double(perClue[0]) : 0
        return Result(cluesUsed: cluesUsed, wrongGuesses: wrongGuesses,
                      solved: solved, total: total, performance: performance)
    }
}

/// Forgiving answer matching: normalize, accept canonical/aliases/last-name, allow 1 typo.
enum AnswerMatcher {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ guess: String, answer: WhoAmIPuzzle.AcceptedAnswer) -> Bool {
        let g = normalize(guess)
        guard !g.isEmpty else { return false }

        var accepted = Set<String>()
        for raw in [answer.canonical] + answer.aliases {
            let n = normalize(raw)
            accepted.insert(n)
            if let last = n.split(separator: " ").last, last.count >= 4 {
                accepted.insert(String(last))   // accept distinctive last name
            }
        }

        for target in accepted {
            if g == target { return true }
            // allow a single-character typo on longer answers
            if target.count >= 5, levenshtein(g, target) <= 1 { return true }
        }
        return false
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
