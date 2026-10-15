import Foundation

/// Smoothed observed outcomes, fitted offline and checked on later unseen games.
/// The separate arcade/coverage modifiers below deliberately change those frequencies.
struct DrillOutcomeModel: Decodable, Sendable {
    let version: Int
    let examples: [String: [String]]
    let globalProbabilities: [String: [String: Double]]
    let probabilities: [String: [String: Double]]

    static func key(_ concept: DrillConcept, state: DrillState) -> String {
        "\(concept.rawValue):\(state.toGo <= 3 ? 0 : state.toGo <= 7 ? 1 : 2):\(state.yardline <= 20 ? 0 : state.yardline <= 50 ? 1 : 2)"
    }
    static func event(_ p: DrillPlay) -> String {
        if p.turnover { return "turnover" }
        if p.call == .fieldGoal { return p.made ? "made" : "miss" }
        if p.sack == true { return "sack" }
        if p.call == .pass && p.complete != true { return "incomplete" }
        return p.yards <= 0 ? "loss" : p.yards <= 3 ? "short" : p.yards < 15 ? "gain" : "explosive"
    }
}

extension DrillBank {
    mutating func indexPlays() {
        let byID = Dictionary(uniqueKeysWithValues: plays.map { ($0.id, $0) })
        arcadePools = outcomeModel?.examples.mapValues { ids in ids.compactMap { byID[$0] } }
        routePools = Dictionary(uniqueKeysWithValues: DrillConcept.allCases.map { concept in
            (concept, plays.filter { concept.matches($0, defense: .blitz) })
        })
    }

    func arcadeChoice(_ concept: DrillConcept, state: DrillState, defense: DrillDefense,
                      target: DrillPlayer?) -> DrillChoice {
        let poolKey = DrillOutcomeModel.key(concept, state: state)
        // Generated examples are indexed at load time: no per-snap sort or network request.
        let pool = arcadePools?[poolKey] ?? Array((routePools?[concept] ?? []).prefix(80))
        let counts = Dictionary(grouping: pool, by: DrillOutcomeModel.event).mapValues(\.count)
        let probabilities = outcomeModel?.probabilities[DrillOutcomeModel.key(concept, state: state)]
            ?? outcomeModel?.globalProbabilities[concept.rawValue]
        let pass = concept.call(against: defense) == .pass
        let weights = pool.map { p -> Double in
            let event = DrillOutcomeModel.event(p)
            var weight = (probabilities?[event] ?? Double(counts[event, default: 0]) / Double(max(1, pool.count)))
                / Double(counts[event, default: 1])
            let positive = p.yards > 0 && !p.turnover
            // Explicit generosity: fewer drive-ending disasters, more gains and highlights.
            switch event {
            case "turnover": weight *= 0.22
            case "sack": weight *= 0.32
            case "incomplete": weight *= 0.75
            case "loss": weight *= 0.6
            case "gain": weight *= 1.3
            case "explosive": weight *= 1.65
            default: break
            }
            if pass, let target, let rate = target.catchRate, p.sack != true {
                let n = Double(target.stats["targets", default: 0])
                let shrunkRate = (rate * n + 0.65 * 40) / (n + 40)
                let adjustment = min(1.2, max(0.8, shrunkRate / 0.65))
                weight *= p.complete == true ? adjustment : 1 / adjustment
            }
            switch defense {
            case .blitz:
                if pass && concept.depth <= 8 && positive { weight *= 1.6 }
                if pass && concept.depth > 8 {
                    if positive { weight *= 0.65 }
                    if p.sack == true || event == "incomplete" { weight *= 1.5 }
                }
            case .loadedBox:
                if !pass && positive { weight *= 0.6 }
                if pass && positive { weight *= 1.35 }
            case .twoHigh:
                if pass && concept.depth >= 17 && positive { weight *= 0.55 }
                if (!pass || concept.depth <= 8) && positive { weight *= 1.25 }
            case .lightBox:
                if !pass && positive { weight *= 1.7 }
                if pass && positive { weight *= 0.9 }
            }
            return max(0.000001, weight)
        }
        let total = weights.reduce(0, +)
        let expected = zip(pool, weights).reduce(0.0) { result, entry in
            let (p, w) = entry
            var utility = Double(min(state.yardline, p.yards))
            if p.yards >= state.toGo { utility += 8 }
            if p.yards >= state.yardline { utility += 24 }
            if p.turnover { utility -= 45 }
            if state.seconds < 25 && !p.stopped && state.timeouts == 0 { utility -= 8 }
            if concept == .kick {
                let useful = state.scenario.offenseScore + 3 >= state.scenario.defenseScore
                utility = p.made ? (useful ? (state.shouldOfferKick ? 45 : 8) : -30) : -30
            }
            return result + utility * w
        } / max(0.000001, total)
        return DrillChoice(concept: concept, pool: pool, weights: weights, expected: expected)
    }
}
