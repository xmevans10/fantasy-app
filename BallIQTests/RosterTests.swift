import XCTest
@testable import BallIQ

/// The pure logic behind `RosterView`: which rung a bot's tile groups under, whether it shows as
/// a silhouette, and what the "your record" block says. All file-scope `static func`s, the same
/// shape as `VersusStatusLineTests`, so none of it needs a live `RepositoryContainer`.
final class RosterTests: XCTestCase {

    private func bot(_ id: String) -> LadderBot {
        LadderBot(id: id, name: id, avatar: "🤖", tagline: "tagline", baseSkill: 0.5, persona: "")
    }

    private func row(rung: Int, botID: String, state: LadderRungState) -> LadderRungRow {
        LadderRungRow(rung: LadderRung(rung: rung, tier: .bronze, mode: .keep4, sport: .nfl,
                                       puzzleId: "p\(rung)", botId: botID, botSkill: 0.5,
                                       timeLimitSeconds: 60, seed: 1, isBoss: false),
                      bot: bot(botID), state: state)
    }

    // MARK: - entries(rows:)

    func testEntriesTakeTheBotsEarliestRung() {
        let rows = [
            row(rung: 12, botID: "nova", state: .cleared),
            row(rung: 3, botID: "nova", state: .cleared),   // earlier — should win
            row(rung: 9, botID: "scout", state: .locked),
        ]
        let nova = RosterView.entries(rows: rows).first { $0.bot.id == "nova" }
        XCTAssertEqual(nova?.firstRung, 3)
    }

    func testEntriesSortByFirstRungAscending() {
        let rows = [
            row(rung: 20, botID: "oracle", state: .locked),
            row(rung: 1, botID: "rookie", state: .cleared),
            row(rung: 8, botID: "analyst", state: .open),
        ]
        let ids = RosterView.entries(rows: rows).map(\.bot.id)
        XCTAssertEqual(ids, ["rookie", "analyst", "oracle"])
    }

    /// A bot's card is a silhouette until its *earliest* rung is reachable — a later rung the
    /// same bot also guards must not leak the character early.
    func testEntriesCarryTheStateOfTheirEarliestRung() {
        let rows = [
            row(rung: 5, botID: "scout", state: .locked),
            row(rung: 22, botID: "scout", state: .locked),
        ]
        XCTAssertEqual(RosterView.entries(rows: rows).first?.state, .locked)
    }

    func testOneEntryPerBotEvenWithManyGuardedRungs() {
        let rows = (1...5).map { row(rung: $0, botID: "rookie", state: .cleared) }
        XCTAssertEqual(RosterView.entries(rows: rows).count, 1)
    }

    // MARK: - recordDisplay(botID:signedIn:records:)

    func testSignedOutAlwaysReadsAsSignedOutRegardlessOfCachedRecords() {
        let records = ["nova": BotRecord(botId: "nova", played: 4, won: 2, bestScore: 0.9, bestBotScore: 0.8)]
        XCTAssertEqual(RosterView.recordDisplay(botID: "nova", signedIn: false, records: records), .signedOut)
    }

    func testSignedInWithNoAttemptsShowsANilRecordNotSignedOut() {
        XCTAssertEqual(RosterView.recordDisplay(botID: "nova", signedIn: true, records: [:]), .record(nil))
    }

    func testSignedInWithAttemptsShowsTheRecord() {
        let record = BotRecord(botId: "nova", played: 4, won: 2, bestScore: 0.9, bestBotScore: 0.8)
        XCTAssertEqual(RosterView.recordDisplay(botID: "nova", signedIn: true, records: ["nova": record]),
                       .record(record))
    }

    // MARK: - BotRecord decoding (see JSONDecoder.supabase's doc comment for the trap this pins)

    /// `my_bot_records()`'s exact row shape. `BotRecord` is camelCase-only with no explicit
    /// `CodingKeys`, so it must go through `.supabase` (`.convertFromSnakeCase`) — the other half
    /// of the rule `SupabaseDecoderTests` pins for `LadderRung`/`LadderBot`, which use explicit
    /// snake keys and need `.supabaseExplicitKeys` instead. Kept here rather than added to
    /// `SupabaseDecoderTests.swift` itself, which isn't in this task's file ownership.
    func testBotRecordDecodesThroughTheConvertFromSnakeCaseDecoder() throws {
        let json = #"[{"bot_id":"nova","played":4,"won":2,"best_score":0.91,"best_bot_score":0.84}]"#
            .data(using: .utf8)!
        let rows = try JSONDecoder.supabase.decode([BotRecord].self, from: json)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.botId, "nova")
        XCTAssertEqual(r.played, 4)
        XCTAssertEqual(r.won, 2)
        XCTAssertEqual(r.bestScore, 0.91, accuracy: 0.0001)
        XCTAssertEqual(r.bestBotScore, 0.84, accuracy: 0.0001)
    }

    /// The failure mode in reverse: if `BotRecord` ever grows explicit snake_case `CodingKeys`,
    /// `.supabaseExplicitKeys` stops matching this exact payload and the RPC starts reading back
    /// `[]` under `try?` — the same silent-outage shape `SupabaseDecoderTests` documents for
    /// `VersusChallenge`.
    func testBotRecordDoesNotDecodeThroughTheExplicitKeysDecoder() {
        let json = #"[{"bot_id":"nova","played":4,"won":2,"best_score":0.91,"best_bot_score":0.84}]"#
            .data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder.supabaseExplicitKeys.decode([BotRecord].self, from: json))
    }
}
