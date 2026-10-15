import XCTest
@testable import BallIQ

final class DrillArcadeTests: XCTestCase {
    func testEveryStartHasRealCompleteLineups() throws {
        let bank = try DrillBank.load()
        for scenario in bank.scenarios {
            let lineup = try XCTUnwrap(bank.lineups?[scenario.id])
            XCTAssertEqual(lineup.offense.count, 11)
            XCTAssertEqual(lineup.defense.count, 11)
            XCTAssertEqual(Set(lineup.offense.map(\.id)).count, 11)
            XCTAssertEqual(Set(lineup.defense.map(\.id)).count, 11)
            XCTAssertEqual(lineup.offense.filter(\.eligible).count, 5)
            XCTAssertEqual(lineup.offense.filter { $0.role == "QB" }.count, 1)
            XCTAssertTrue((lineup.offense + lineup.defense).allSatisfy { !$0.name.isEmpty && $0.jersey >= 0 && $0.jersey <= 99 })
        }
    }
    func testConceptCoverageAndReproducibleDraws() throws {
        let bank = try DrillBank.load()
        // Both ends of the season, every concept, every defensive look.
        for scenario in [bank.scenarios.first!, bank.scenarios.last!] {
            let state = DrillState(scenario)
            for defense in DrillDefense.allCases {
                for concept in DrillConcept.allCases {
                    let choice = bank.choice(concept, state: state, defense: defense, target: nil)
                    XCTAssertFalse(choice.pool.isEmpty, "\(concept) / \(defense)")
                    XCTAssertEqual(choice.draw(seed: 123)?.id, choice.draw(seed: 123)?.id)
                    XCTAssertTrue(choice.weights.allSatisfy { $0 > 0 && $0.isFinite })
                    XCTAssertTrue(choice.expected.isFinite)
                    XCTAssertEqual(choice.quality(best: choice.expected), 1)
                }
            }
        }
    }
    func testRouteDirectionAndDepthAreMeaningful() throws {
        let bank = try DrillBank.load()
        let state = DrillState(bank.scenarios[0])
        for route in DrillConcept.routes {
            let choice = bank.choice(route, state: state, defense: .lightBox, target: nil)
            XCTAssertTrue(choice.pool.allSatisfy { route.matches($0, defense: .lightBox) })
        }
        let slants = bank.choice(.slant, state: state, defense: .blitz, target: nil).pool.filter { $0.sack != true }
        let outs = bank.choice(.out, state: state, defense: .blitz, target: nil).pool.filter { $0.sack != true }
        XCTAssertTrue(slants.allSatisfy { $0.side == "middle" })
        XCTAssertTrue(outs.allSatisfy { $0.side != "middle" })
        XCTAssertTrue(Set(slants.map(\.id)).isDisjoint(with: Set(outs.map(\.id))))
    }
    func testRPOReadsTheBoxAndTricksUseObservedDescriptions() throws {
        XCTAssertEqual(DrillConcept.rpo.call(against: .lightBox), .run)
        XCTAssertEqual(DrillConcept.rpo.call(against: .twoHigh), .run)
        XCTAssertEqual(DrillConcept.rpo.call(against: .blitz), .pass)
        XCTAssertEqual(DrillConcept.rpo.call(against: .loadedBox), .pass)
        let bank = try DrillBank.load()
        for concept in DrillConcept.tricks {
            let choice = bank.choice(concept, state: DrillState(bank.scenarios[0]), defense: .blitz, target: nil)
            XCTAssertTrue(choice.pool.allSatisfy { $0.trick == true })
        }
    }
    func testDefensiveReadAndPlayerCatchRateAffectOdds() throws {
        let bank = try DrillBank.load()
        let state = DrillState(bank.scenarios[0])
        let ordinary = bank.choice(.post, state: state, defense: .loadedBox, target: nil)
        let fake = bank.choice(.post, state: state, defense: .loadedBox, target: nil, options: .init(playAction: true))
        XCTAssertGreaterThan(fake.averageYards, ordinary.averageYards)
        let weak = DrillPlayer(id: "w", name: "Test receiver", jersey: 1, position: "WR", role: "WR1", headshot: "", stats: ["targets": 100, "catches": 20])
        let strong = DrillPlayer(id: "s", name: "Test receiver", jersey: 2, position: "WR", role: "WR2", headshot: "", stats: ["targets": 100, "catches": 90])
        XCTAssertGreaterThan(bank.choice(.slant, state: state, defense: .lightBox, target: strong).completion,
                             bank.choice(.slant, state: state, defense: .lightBox, target: weak).completion)
    }
    func testTempoExpiryAndDecisionScore() throws {
        let bank = try DrillBank.load()
        let play = bank.plays.first { $0.call == .run && $0.yards > 0 && !$0.turnover }!
        var slow = DrillState(bank.scenarios[0]); slow.running = true; slow.seconds = 30
        slow.snap(play, tempo: .milk, grade: 1)
        XCTAssertEqual(slow.snaps, 0)
        XCTAssertNotNil(slow.ended)
        XCTAssertEqual(slow.meanGrade, 0)
        var hurry = DrillState(bank.scenarios[0]); hurry.running = true; hurry.seconds = 30
        hurry.snap(play, tempo: .hurry, grade: 1)
        XCTAssertEqual(hurry.seconds, 4)
        XCTAssertEqual(hurry.snaps, 1)
        XCTAssertEqual(hurry.meanGrade, 1)
        XCTAssertGreaterThanOrEqual(hurry.score, 200)
        XCTAssertLessThanOrEqual(hurry.score, 1000)
    }
    func testKneelUsesClockAndLosesARealDownWithoutInventingASourcedPlay() throws {
        let bank = try DrillBank.load()
        var state = DrillState(bank.scenarios[0])
        let yardline = state.yardline
        state.seconds = 60
        state.kneel()
        XCTAssertEqual(state.yardline, yardline + 1)
        XCTAssertEqual(state.down, 2)
        XCTAssertEqual(state.seconds, 54)
        XCTAssertTrue(state.running)
        XCTAssertEqual(state.meanGrade, 0)
        XCTAssertTrue(state.log[0].contains("ARCADE CLOCK RULE"))
    }

    func testScoringPlayNarratesOnlyTheVirtualYardsToTheGoal() throws {
        let bank = try DrillBank.load()
        let play = bank.plays.first { $0.call == .pass && $0.complete == true && !$0.turnover && $0.yards > 20 }!
        var before = DrillState(bank.scenarios[0]); before.yardline = 5; before.toGo = 5
        var after = before; after.snap(play, grade: 1)
        let p = DrillPresentation(before: before, after: after, play: play, concept: .go, target: nil,
            defense: .twoHigh, quality: 1, bestTitle: "GO", quarterback: "QB")
        XCTAssertEqual(after.points, 6)
        XCTAssertEqual(p.creditedYards, 5)
        XCTAssertTrue(p.narration.contains("5 yards"))
    }

    func testOfflineModelHasFiniteSupportedProbabilitiesAndFastPools() throws {
        let bank = try DrillBank.load()
        let model = try XCTUnwrap(bank.outcomeModel)
        XCTAssertEqual(model.version, 1)
        XCTAssertEqual(model.probabilities.count, 63)
        for scenario in bank.scenarios {
            let state = DrillState(scenario)
            for concept in DrillConcept.simple {
                let key = DrillOutcomeModel.key(concept, state: state)
                let probabilities = try XCTUnwrap(model.probabilities[key])
                XCTAssertEqual(probabilities.values.reduce(0, +), 1, accuracy: 0.000001)
                let pool = try XCTUnwrap(bank.arcadePools?[key])
                XCTAssertFalse(pool.isEmpty)
                XCTAssertTrue(pool.allSatisfy { concept.matches($0, defense: .blitz) })
                let choice = bank.arcadeChoice(concept, state: state, defense: .blitz, target: nil)
                XCTAssertTrue(choice.weights.allSatisfy { $0 > 0 && $0.isFinite })
                XCTAssertEqual(choice.draw(seed: 12)?.id, choice.draw(seed: 12)?.id)
            }
        }
    }

    func testSimpleClockScoringAndUsefulKickOffer() throws {
        let bank = try DrillBank.load()
        let play = bank.plays.first { $0.call == .run && $0.yards == 5 && !$0.turnover }!
        var state = DrillState(bank.scenarios[0]); state.seconds = 90; state.running = true
        state.arcadeSnap(play, grade: 1)
        XCTAssertEqual(state.seconds, 76)
        XCTAssertEqual(state.snaps, 1)
        let noScore = state.score
        state.points = 6
        XCTAssertTrue(state.won)
        XCTAssertGreaterThan(state.score, noScore)
        XCTAssertEqual(state.score, 1000)
        state.points = 0; state.ended = nil; state.yardline = 25; state.down = 1; state.seconds = 60
        XCTAssertFalse(state.shouldOfferKick)
        state.down = 4
        XCTAssertEqual(state.shouldOfferKick, state.scenario.offenseScore + 3 >= state.scenario.defenseScore)
    }

    func testHistoricalRevealStartsAtTheSameSnapAndNeverUsesOtherGames() throws {
        let bank = try DrillBank.load()
        for scenario in bank.scenarios {
            let history = try XCTUnwrap(scenario.history)
            XCTAssertEqual(history.first?.id, scenario.id)
            XCTAssertTrue(history.allSatisfy { $0.id.hasPrefix(scenario.game + ":") && !$0.description.isEmpty })
        }
    }

}
