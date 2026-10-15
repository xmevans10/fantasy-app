import Foundation

struct DrillLineup: Decodable, Sendable {
    let offense: [DrillPlayer]
    let defense: [DrillPlayer]
    var specialists: [DrillPlayer]?
}

struct DrillPlayer: Decodable, Identifiable {
    let id: String
    let name: String
    let jersey: Int
    let position: String
    let role: String
    let headshot: String
    let stats: [String: Int]
    var shortName: String {
        let parts = name.split(separator: " ")
        return parts.count > 1 ? "\(parts[0].prefix(1)). \(parts.dropFirst().joined(separator: " "))" : name
    }
    var eligible: Bool { ["WR1", "WR2", "WR3", "TE", "RB"].contains(role) }
    var catchRate: Double? {
        guard let targets = stats["targets"], targets >= 5 else { return nil }
        return Double(stats["catches", default: 0]) / Double(targets)
    }
}

enum DrillTempo: String, CaseIterable, Identifiable {
    case hurry, huddle, milk
    var id: String { rawValue }
    var title: String { switch self { case .hurry: return "NO HUDDLE"; case .huddle: return "HUDDLE"; case .milk: return "MILK CLOCK" } }
    var seconds: Int { switch self { case .hurry: return 20; case .huddle: return 32; case .milk: return 38 } }
}

enum DrillDefense: String, CaseIterable {
    case blitz, loadedBox, twoHigh, lightBox
    var title: String { switch self { case .blitz: return "BLITZ SHOWING"; case .loadedBox: return "LOADED BOX"; case .twoHigh: return "TWO HIGH"; case .lightBox: return "LIGHT BOX" } }
    var detail: String {
        switch self {
        case .blitz: return "Pressure coming. Get the ball out before the rush arrives."
        case .loadedBox: return "Extra bodies crowd the run lanes. A fake can pull the linebackers in."
        case .twoHigh: return "Two deep safeties. Underneath space, crowded deep windows."
        case .lightBox: return "Extra men in coverage. The run has room to breathe."
        }
    }
    static func draw(seed: UInt64, snap: Int) -> Self {
        allCases[Int(DrillBank.seed("read-\(seed)-\(snap)") % UInt64(allCases.count))]
    }
}

enum DrillConcept: String, CaseIterable, Identifiable {
    case inside, outsideLeft, outsideRight, keeper, screen, slant, out, post, go, rpo, reverse, fleaFlicker, kick
    var id: String { rawValue }
    static let runs: [Self] = [.inside, .outsideLeft, .outsideRight, .keeper]
    static let routes: [Self] = [.screen, .slant, .out, .post, .go]
    static let tricks: [Self] = [.reverse, .fleaFlicker]
    var title: String {
        switch self {
        case .inside: return "INSIDE ZONE"
        case .outsideLeft: return "SWEEP LEFT"
        case .outsideRight: return "SWEEP RIGHT"
        case .keeper: return "QB KEEPER"
        case .screen: return "SCREEN"
        case .slant: return "SLANT"
        case .out: return "OUT"
        case .post: return "POST"
        case .go: return "GO"
        case .rpo: return "READ OPTION"
        case .reverse: return "REVERSE"
        case .fleaFlicker: return "FLEA FLICKER"
        case .kick: return "FIELD GOAL"
        }
    }
    static func defaultForRole(_ role: String) -> Self {
        switch role {
        case "RB": return .screen
        case "TE": return .out
        case "WR1": return .slant
        case "WR3": return .post
        default: return .go
        }
    }
    var depth: Double {
        switch self {
        case .screen, .reverse: return 2
        case .slant, .out, .rpo: return 8
        case .post, .fleaFlicker: return 17
        case .go: return 25
        default: return 5
        }
    }
    func call(against defense: DrillDefense) -> DrillCall {
        if self == .kick { return .fieldGoal }
        if Self.runs.contains(self) || self == .reverse { return .run }
        if self == .rpo && (defense == .lightBox || defense == .twoHigh) { return .run }
        return .pass
    }
    func matches(_ play: DrillPlay, defense: DrillDefense) -> Bool {
        guard play.call == call(against: defense) else { return false }
        switch self {
        case .inside: return play.side == "middle" && play.qbRun != true
        case .outsideLeft: return play.side == "left" && play.qbRun != true
        case .outsideRight: return play.side == "right" && play.qbRun != true
        case .keeper: return play.qbRun == true
        case .screen: return play.sack == true || (play.air.map { $0 <= 0 } ?? false)
        case .slant: return play.sack == true || ((play.air.map { (1...9).contains($0) } ?? false) && play.side == "middle")
        case .out: return play.sack == true || ((play.air.map { (1...9).contains($0) } ?? false) && ["left", "right"].contains(play.side ?? ""))
        case .post: return play.sack == true || (play.air.map { (10...19).contains($0) } ?? false)
        case .go: return play.sack == true || (play.air.map { $0 >= 20 } ?? false)
        case .reverse, .fleaFlicker: return play.trick == true
        case .rpo: return play.call == .run || play.sack == true || (play.air.map { $0 <= 8 } ?? false)
        case .kick: return true
        }
    }
}

struct DrillPlayOptions: Equatable, Sendable {
    var playAction = false
    var rollout = false
    var sideline = false
}

struct DrillChoice: Sendable {
    let concept: DrillConcept
    let pool: [DrillPlay]
    let weights: [Double]
    let expected: Double
    var averageYards: Double { weighted { Double($0.yards) } }
    var completion: Double { weighted { $0.complete == true ? 1 : 0 } }
    var turnover: Double { weighted { $0.turnover ? 1 : 0 } }
    var stopped: Double { weighted { $0.stopped ? 1 : 0 } }
    var kickSuccess: Double { weighted { $0.made ? 1 : 0 } }
    private func weighted(_ metric: (DrillPlay) -> Double) -> Double {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        return zip(pool, weights).reduce(0) { $0 + metric($1.0) * $1.1 } / total
    }
    func draw(seed: UInt64) -> DrillPlay? {
        guard !pool.isEmpty else { return nil }
        var remaining = Double(seed % 1_000_000) / 1_000_000 * weights.reduce(0, +)
        for (play, weight) in zip(pool, weights) {
            remaining -= weight
            if remaining < 0 { return play }
        }
        return pool.last
    }
    func quality(best: Double) -> Double { min(1, max(0, 1 - (best - expected) / 22)) }
}

extension DrillBank {
    /// Route families map to observed pass depths/run direction; formations and defensive
    /// effects are explicitly arcade rules, not claimed tracking data or win probability.
    func choice(_ concept: DrillConcept, state: DrillState, defense: DrillDefense,
                target: DrillPlayer?, options: DrillPlayOptions = .init()) -> DrillChoice {
        let eligible = plays.filter { concept.matches($0, defense: defense) }
        func distance(_ p: DrillPlay) -> Int {
            abs(p.yardline - state.yardline) + abs(p.toGo - state.toGo) * 5
                + (concept == .kick || p.down == state.down ? 0 : 80)
        }
        let pool = Array(eligible.sorted {
            let a = distance($0), b = distance($1)
            return a == b ? $0.id < $1.id : a < b
        }.prefix(80))
        let baseCatch = Double(pool.filter { $0.complete == true }.count) / Double(max(1, pool.count))
        let weights = pool.map { p -> Double in
            var w = 1.0
            let success = p.yards > 0 && !p.turnover
            let pass = concept.call(against: defense) == .pass
            if pass, let rate = target?.catchRate, baseCatch > 0 && baseCatch < 1, p.sack != true {
                w *= p.complete == true ? rate / baseCatch : (1 - rate) / (1 - baseCatch)
            }
            switch defense {
            case .blitz:
                if pass && concept.depth <= 8 && success { w *= 1.6 }
                if pass && concept.depth > 8 && (p.sack == true || p.turnover) { w *= 2 }
            case .loadedBox:
                if !pass && !success { w *= 1.7 }
                if pass && options.playAction && success { w *= 1.7 }
            case .twoHigh:
                if pass && concept.depth >= 17 && success { w *= 0.6 }
                if !pass && success { w *= 1.3 }
            case .lightBox:
                if !pass && success { w *= 1.6 }
                if pass && p.turnover { w *= 1.3 }
            }
            if options.playAction && defense == .blitz && p.sack == true { w *= 1.6 }
            if options.sideline && p.stopped { w *= 1.7 }
            if options.sideline && success && p.yards > 12 { w *= 0.7 }
            if options.rollout && p.sack == true { w *= 0.7 }
            if options.rollout && p.complete == false { w *= 1.15 }
            return max(0.05, w)
        }
        let total = weights.reduce(0, +)
        let expected = zip(pool, weights).reduce(0.0) { result, entry in
            let (p, w) = entry
            var utility = Double(min(state.yardline, p.yards))
            if p.yards >= state.toGo { utility += 8 }
            if p.turnover { utility -= 45 }
            if state.seconds < 40 && !p.stopped && state.timeouts == 0 { utility -= 12 }
            if concept == .kick {
                let useful = state.scenario.offenseScore + 3 >= state.scenario.defenseScore
                utility = p.made ? (useful ? 28 : -15) : -25
            }
            return result + utility * w
        } / max(0.01, total)
        return DrillChoice(concept: concept, pool: pool, weights: weights, expected: expected)
    }
}

enum DrillAnimationPhase: Int { case set, snap, develop, flight, contact, result }

struct DrillPresentation: Identifiable {
    let id = UUID()
    let before: DrillState
    let after: DrillState
    let play: DrillPlay
    let concept: DrillConcept
    let target: DrillPlayer?
    let defense: DrillDefense
    let quality: Double
    let bestTitle: String
    let quarterback: String
    var creditedYards: Int { max(before.yardline - 100, min(before.yardline, play.yards)) }
    var grade: String { quality >= 0.9 ? "GREAT CALL" : quality >= 0.7 ? "SOLID READ" : quality >= 0.4 ? "COSTLY CALL" : "BAD READ" }
    var headline: String {
        if after.snaps == before.snaps { return after.ended?.uppercased() ?? "CLOCK STOPPED" }
        if play.id == "clock-kneel" { return "TAKE A KNEE" }
        if play.turnover { return "TURNOVER!" }
        if after.points == 6 { return "TOUCHDOWN!" }
        if concept == .kick { return play.made ? "IT’S GOOD!" : "NO GOOD" }
        if play.sack == true { return "SACKED!" }
        if play.call == .pass && play.complete != true { return "INCOMPLETE" }
        if play.yards >= before.toGo { return "MOVE THE CHAINS!" }
        return creditedYards > 0 ? "+\(creditedYards) YARDS" : "STUFFED!"
    }
    var narration: String {
        let who = target?.shortName ?? "The ball carrier"
        if after.snaps == before.snaps { return after.ended == "Turnover on downs" ? "A fourth-down spike gives possession to the defense." : "The offense couldn’t get another snap off before time expired." }
        if play.id == "clock-kneel" { return "\(quarterback) takes a knee. One yard lost. The clock keeps running." }
        if concept == .kick { return "\(before.yardline + 17)-yard attempt. \(play.made ? "Through the uprights." : "The kick is no good.")" }
        if play.sack == true { return "The pocket collapses. \(quarterback) goes down for a \(abs(play.yards))-yard loss." }
        if play.turnover { return play.call == .pass ? "\(quarterback) fires into traffic. The defense takes it away." : "\(who) loses the ball in contact. The defense recovers." }
        if play.call == .pass && play.complete != true { return "\(quarterback) looks for \(who) on the \(concept.title.lowercased()). The throw falls incomplete." }
        let action = play.call == .pass ? "\(quarterback) finds \(who) on the \(concept.title.lowercased())" : "\(who) takes the \(concept.title.lowercased())"
        return "\(action). \(creditedYards) yards. \(after.points == 6 ? "Into the end zone!" : play.stopped ? "Out of bounds. Clock stopped." : "Wrapped up in bounds. The clock is running.")"
    }
}
