// Compile with the shipping model files; see docs/TWO_MINUTE_DRILL.md.
import Foundation

// The app's stable seed function lives in a SwiftUI view file. Identical FNV-1a
// adapter lets this command-line harness exercise the shipping engine on macOS.
enum SeededGenerator {
    static func stableHash(_ string: String) -> UInt64 {
        string.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

@main struct VerifyDrill {
    static func main() throws {
        var bank = try JSONDecoder().decode(DrillBank.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        bank.indexPlays()
        let runs = Int(CommandLine.arguments.dropFirst(2).first ?? "10")!
        var report: [String: Any] = [:]
        for policy in ["smart", "read", "random", "poor"] {
            var wins = 0, touchdowns = 0, snaps = 0, disasters = 0
            var perStart: [String: Int] = [:]
            for scenario in bank.scenarios {
                let target = bank.lineups?[scenario.id]?.offense.first { $0.role == "WR1" }
                for run in 0..<runs {
                    var state = DrillState(scenario)
                    let seed = DrillBank.seed("verify-\(scenario.id)-\(run)")
                    for index in 0..<24 where state.ended == nil {
                        if state.running && state.seconds <= 22 && state.timeouts > 0 { state.timeout() }
                        let defense = DrillDefense.draw(seed: seed, snap: index)
                        let choices = DrillConcept.simple.filter { $0 != .kick || state.shouldOfferKick }.map {
                            bank.arcadeChoice($0, state: state, defense: defense, target: target)
                        }
                        let best = choices.max { $0.expected < $1.expected }!
                        let choice: DrillChoice
                        if state.shouldOfferKick { choice = choices.first { $0.concept == .kick }! }
                        else if policy == "smart" { choice = best }
                        else if policy == "read" {
                            let route: DrillConcept = defense == .lightBox ? .inside : defense == .loadedBox && state.yardline > 15 ? .post : .slant
                            choice = choices.first { $0.concept == route }!
                        }
                        else if policy == "poor" { choice = choices.filter { $0.concept != .kick }.min { $0.expected < $1.expected }! }
                        else { choice = choices.filter { $0.concept != .kick }[Int(DrillBank.seed("pick-\(seed)-\(index)") % 6)] }
                        let play = choice.draw(seed: DrillBank.seed("draw-\(seed)-\(index)"))!
                        state.arcadeSnap(play, grade: choice.quality(best: best.expected))
                    }
                    precondition(state.ended != nil && (0...1000).contains(state.score))
                    if state.won { wins += 1; perStart[scenario.id, default: 0] += 1 }
                    if state.points == 6 { touchdowns += 1 }
                    if state.ended == "Turnover" { disasters += 1 }
                    snaps += state.snaps
                }
            }
            let drives = bank.scenarios.count * runs
            report[policy] = ["drives": drives, "wins": wins, "winRate": Double(wins) / Double(drives),
                              "touchdowns": touchdowns, "turnovers": disasters, "averageSnaps": Double(snaps) / Double(drives),
                              "perStartWins": perStart]
            print("\(policy): \(wins)/\(drives) wins, \(touchdowns) TD, \(disasters) turnovers")
        }
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "/tmp/drill-balance.json"))
    }
}
