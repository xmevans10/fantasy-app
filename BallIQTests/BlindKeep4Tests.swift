import XCTest
@testable import BallIQ

final class BlindKeep4Tests: XCTestCase {

    private func makePuzzle(id: String = "t") -> Keep4Puzzle {
        let players = (0..<8).map { i in
            PlayerSeason(id: "p\(i)", name: "P\(i)", teamAbbr: "TM",
                         seasonYear: 2000 + i, stats: [], grade: Double(80 - i * 10))
        }
        return Keep4Puzzle(id: id, theme: "Test", sport: .nfl, players: players)
    }

    func testBlindOrderIsDeterministic() {
        let p = makePuzzle()
        let a = Keep4GameView.blindOrder(for: p).map(\.id)
        let b = Keep4GameView.blindOrder(for: p).map(\.id)
        XCTAssertEqual(a, b, "Same puzzle must serve the same order for everyone")
    }

    func testBlindOrderIsAPermutation() {
        let p = makePuzzle()
        let ordered = Keep4GameView.blindOrder(for: p).map(\.id).sorted()
        XCTAssertEqual(ordered, p.players.map(\.id).sorted())
    }

    func testDifferentPuzzlesGetDifferentOrders() {
        let a = Keep4GameView.blindOrder(for: makePuzzle(id: "a")).map(\.id)
        let b = Keep4GameView.blindOrder(for: makePuzzle(id: "b")).map(\.id)
        XCTAssertNotEqual(a, b)
    }

    /// Mirror the view's cap rule: a full pile forces overflow into the other. This must always
    /// land at exactly 4/4 for 8 cards, regardless of what the player prefers.
    private func resolve(order: [PlayerSeason], preferred: [Pile], limit: Int = 4) -> [String: Pile] {
        var placement: [String: Pile] = [:]
        var keep = 0, cut = 0
        for (i, player) in order.enumerated() {
            var pile = preferred[i]
            if pile == .keep, keep >= limit { pile = .cut }
            else if pile == .cut, cut >= limit { pile = .keep }
            placement[player.id] = pile
            if pile == .keep { keep += 1 } else { cut += 1 }
        }
        return placement
    }

    func testForcedTailAlwaysReachesFourFour() {
        let order = makePuzzle().players
        let scenarios: [[Pile]] = [
            Array(repeating: .keep, count: 8),                 // tries to keep everyone
            Array(repeating: .cut, count: 8),                  // tries to cut everyone
            (0..<8).map { $0 % 2 == 0 ? .keep : .cut },        // alternating
            [.keep, .keep, .keep, .cut, .keep, .keep, .cut, .cut] // 5 keeps requested early
        ]
        for pref in scenarios {
            let placement = resolve(order: order, preferred: pref)
            XCTAssertEqual(placement.values.filter { $0 == .keep }.count, 4)
            XCTAssertEqual(placement.values.filter { $0 == .cut }.count, 4)
            XCTAssertEqual(placement.count, 8)
        }
    }
}
