import XCTest
@testable import BallIQ

final class TwoMinuteDrillTests: XCTestCase {
    private func scenario(seconds: Int = 90, yardline: Int = 70, timeouts: Int = 2) -> DrillScenario {
        DrillScenario(id: "test", game: "2024_test", date: "2024-10-01", offense: "NO", defense: "ATL",
            offenseScore: 17, defenseScore: 20, seconds: seconds, yardline: yardline, toGo: 10,
            timeouts: timeouts, actualResult: "Punt")
    }
    private func play(_ yards: Int = 5, stopped: Bool = false, turnover: Bool = false,
                      call: DrillCall = .run, made: Bool = false) -> DrillPlay {
        DrillPlay(id: "p", game: "source", call: call, down: 1, toGo: 10, yardline: 70,
                  yards: yards, turnover: turnover, stopped: stopped, made: made, description: "Observed play")
    }
    func testRunoffAndTimeout() {
        var s = DrillState(scenario())
        s.snap(play())
        XCTAssertEqual(s.seconds, 84)
        XCTAssertEqual(s.down, 2)
        s.snap(play())
        XCTAssertEqual(s.seconds, 58)
        XCTAssertEqual(s.down, 1)
        s.timeout()
        XCTAssertEqual(s.timeouts, 1)
        s.snap(play(stopped: true))
        XCTAssertEqual(s.seconds, 52)
        XCTAssertFalse(s.running)
    }
    func testNoTimeoutWhenStoppedOrEmpty() {
        var s = DrillState(scenario(timeouts: 0))
        s.timeout()
        XCTAssertEqual(s.timeouts, 0)
        s.snap(play())
        s.timeout()
        XCTAssertTrue(s.running)
    }
    func testFourthDownSpikeAndTerminalLatch() {
        var s = DrillState(scenario())
        s.down = 4; s.running = true
        s.spike()
        XCTAssertEqual(s.ended, "Turnover on downs")
        let seconds = s.seconds
        s.snap(play(70)); s.timeout(); s.spike()
        XCTAssertEqual(s.seconds, seconds)
        XCTAssertEqual(s.points, 0)
    }
    func testFinalSnapCanScoreButRunoffCannot() {
        var s = DrillState(scenario(seconds: 1, yardline: 5))
        s.snap(play(7))
        XCTAssertEqual(s.points, 6)
        XCTAssertEqual(s.score, 1000)
        XCTAssertEqual(s.seconds, 0)
        var running = DrillState(scenario(seconds: 20, yardline: 5))
        running.running = true
        running.snap(play(7))
        XCTAssertEqual(running.points, 0)
        XCTAssertEqual(running.snaps, 0)
        XCTAssertNotNil(running.ended)
    }
    func testLossesAndGoalToGo() {
        var s = DrillState(scenario(yardline: 15))
        s.snap(play(11, stopped: true))
        XCTAssertEqual(s.toGo, 4)
        XCTAssertEqual(s.down, 1)
        s.snap(play(-3))
        XCTAssertEqual(s.toGo, 7)
        XCTAssertEqual(s.yardline, 7)
    }
    func testTurnoverAndKickRange() {
        var s = DrillState(scenario())
        s.snap(play(call: .fieldGoal, made: true))
        XCTAssertEqual(s.snaps, 0)
        s.snap(play(turnover: true))
        XCTAssertEqual(s.ended, "Turnover")
        var kick = DrillState(scenario(yardline: 25))
        kick.snap(play(call: .fieldGoal, made: true))
        XCTAssertEqual(kick.points, 3)
        XCTAssertEqual(kick.score, 600)
    }
    func testBundledDataAndDeterministicSampling() throws {
        let bank = try DrillBank.load()
        XCTAssertEqual(bank.scenarios.count, 53)
        XCTAssertEqual(bank.plays.count, 33936)
        XCTAssertEqual(Set(bank.plays.map(\.id)).count, bank.plays.count)
        for scenario in bank.scenarios {
            XCTAssertTrue((30...120).contains(scenario.seconds))
            XCTAssertTrue((0...5).contains(scenario.defenseScore - scenario.offenseScore))
            for call in DrillCall.allCases {
                let pool = bank.candidates(call, state: DrillState(scenario))
                XCTAssertEqual(pool.count, 40)
                XCTAssertTrue(pool.allSatisfy { $0.call == call })
            }
        }
        XCTAssertEqual(DrillBank.seed("hello"), 0xa430d84680aabd0b)
        XCTAssertNotEqual(DrillBank.seed("2026-10-15"), DrillBank.seed("2026-10-16"))
        XCTAssertEqual(DrillBank.dayKey(Date(timeIntervalSince1970: 0)), "1970-01-01")
    }
    func testEveryScenarioFinishesAndScoreIsBounded() throws {
        let bank = try DrillBank.load()
        for scenario in bank.scenarios {
            for call in [DrillCall.run, .pass] {
                var state = DrillState(scenario)
                for _ in 0..<40 where state.ended == nil {
                    state.snap(bank.candidates(call, state: state)[0])
                    XCTAssertTrue((0...1000).contains(state.score))
                    XCTAssertGreaterThanOrEqual(state.seconds, 0)
                }
                XCTAssertNotNil(state.ended, scenario.id)
            }
        }
    }
}
