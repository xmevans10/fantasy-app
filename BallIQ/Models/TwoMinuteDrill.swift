import Foundation

struct DrillBank: Decodable {
    let season: Int
    let source: String
    let scenarios: [DrillScenario]
    let plays: [DrillPlay]

    static func load() throws -> DrillBank {
        guard let url = Bundle.main.url(forResource: "two_minute_drill", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let bank = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !bank.scenarios.isEmpty, DrillCall.allCases.allSatisfy({ call in
            bank.plays.contains { $0.call == call }
        }) else { throw CocoaError(.coderReadCorrupt) }
        return bank
    }

    /// Stable UTC daily; no Hasher (randomized across launches), no server dependency.
    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func seed(_ key: String) -> UInt64 {
        SeededGenerator.stableHash(key)
    }

    /// Same down, nearest distance/field position. League-wide 2024 outcomes, never fake
    /// defensive reads or invented player ratings. FG matching uses distance to the goal.
    func candidates(_ call: DrillCall, state: DrillState) -> [DrillPlay] {
        let eligible = plays.filter { $0.call == call && (call == .fieldGoal || $0.down == state.down) }
        func distance(_ p: DrillPlay) -> Int {
            abs(p.yardline - state.yardline) + (call == .fieldGoal ? 0 : abs(p.toGo - state.toGo) * 5)
        }
        return Array(eligible.sorted {
            let a = distance($0), b = distance($1)
            return a == b ? $0.id < $1.id : a < b
        }.prefix(40))
    }
}

struct DrillScenario: Codable, Identifiable {
    let id: String
    let game: String
    let date: String
    let offense: String
    let defense: String
    let offenseScore: Int
    let defenseScore: Int
    let seconds: Int
    let yardline: Int
    let toGo: Int
    let timeouts: Int
    let actualResult: String
}

enum DrillCall: String, Codable, CaseIterable {
    case run, pass, fieldGoal = "field_goal"
    var title: String {
        switch self { case .run: return "RUN"; case .pass: return "PASS"; case .fieldGoal: return "FIELD GOAL" }
    }
    var symbol: String {
        switch self { case .run: return "figure.run"; case .pass: return "arrow.up.right"; case .fieldGoal: return "sportscourt" }
    }
}

struct DrillPlay: Codable, Identifiable {
    let id: String
    let game: String
    let call: DrillCall
    let down: Int
    let toGo: Int
    let yardline: Int
    let yards: Int
    let turnover: Bool
    let stopped: Bool
    let made: Bool
    let description: String
}

struct DrillState {
    let scenario: DrillScenario
    var seconds: Int
    var yardline: Int
    var toGo: Int
    var down = 1
    var timeouts: Int
    var running = false
    var points = 0
    var ended: String?
    var log: [String] = []
    var snaps = 0

    init(_ scenario: DrillScenario) {
        self.scenario = scenario
        seconds = scenario.seconds
        yardline = scenario.yardline
        toGo = scenario.toGo
        timeouts = scenario.timeouts
    }

    var clock: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
    var fieldPosition: String { yardline > 50 ? "Own \(100 - yardline)" : yardline == 50 ? "Midfield" : "Opp \(yardline)" }
    var situation: String { "\(down)\(["st", "nd", "rd", "th"][min(3, max(0, down - 1))]) & \(toGo) · \(fieldPosition)" }
    var canKick: Bool { yardline <= 45 && ended == nil }
    var score: Int {
        let gain = max(0, scenario.yardline - yardline)
        if points == 6 { return 1000 }
        if points == 3 { return scenario.offenseScore + 3 > scenario.defenseScore ? 800 : 600 }
        return min(400, gain * 5)
    }

    mutating func timeout() {
        guard ended == nil, running, timeouts > 0 else { return }
        timeouts -= 1
        running = false
        log.insert("TIMEOUT · \(timeouts) remaining · \(clock)", at: 0)
    }

    mutating func spike() {
        guard ended == nil, running else { return }
        seconds = max(0, seconds - 3)
        down += 1
        running = false
        log.insert("SPIKE · 3 seconds · lose a down", at: 0)
        if seconds == 0 { ended = "Time expired" }
        else if down > 4 { ended = "Turnover on downs" }
    }

    mutating func snap(_ play: DrillPlay) {
        guard ended == nil, play.call != .fieldGoal || canKick else { return }
        if running {
            seconds = max(0, seconds - 20)
            if seconds == 0 { ended = "Time expired before the snap"; return }
        }
        snaps += 1
        seconds = max(0, seconds - 6)
        running = !play.stopped
        // A play snapped before 0:00 can finish after the clock expires.
        if play.turnover { ended = "Turnover" }
        else if play.call == .fieldGoal {
            points = play.made ? 3 : 0
            ended = play.made ? "Field goal!" : "Field goal missed"
        } else {
            yardline = min(100, max(0, yardline - play.yards))
            if yardline == 0 { points = 6; ended = "Touchdown!" }
            else if yardline == 100 { ended = "Safety" }
            else if play.yards >= toGo { down = 1; toGo = min(10, yardline) }
            else { down += 1; toGo = min(yardline, max(1, toGo - play.yards)) }
            if ended == nil && down > 4 { ended = "Turnover on downs" }
        }
        if ended == nil && seconds == 0 { ended = "Time expired" }
        log.insert("\(play.call.title) · \(play.call == .fieldGoal ? (play.made ? "GOOD" : "NO GOOD") : "\(play.yards) yards") · \(clock)\nSource: \(play.game)\n\(play.description)", at: 0)
    }
}
