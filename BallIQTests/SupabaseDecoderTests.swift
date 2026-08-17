import XCTest
@testable import BallIQ

/// Pins the difference between `JSONDecoder.supabase` and `JSONDecoder.supabaseExplicitKeys`,
/// and pins `VersusChallenge`/`VersusSeries` to the right one.
///
/// **Why this file exists.** `VersusChallenge` shipped with explicit snake_case `CodingKeys`
/// (`case seriesId = "series_id"`) and was fetched through `client.select`, whose default
/// decoder is `.supabase` — which sets `.convertFromSnakeCase`. That strategy rewrites the
/// incoming key `series_id` to `seriesId` *before* the container looks it up, so a `CodingKeys`
/// case whose `stringValue` is `"series_id"` never matches and the row throws `keyNotFound`.
/// Every Versus fetch wraps its `select` in `try?`, so the throw surfaced as an empty array:
/// from the day the feature shipped until 2026-08-13, the Versus tab could not render a duel
/// even when the row existed server-side. It looked exactly like "nobody has any challenges".
///
/// Nothing about that failure is visible at the call site, which is why it is pinned here
/// rather than left to a code review.
final class SupabaseDecoderTests: XCTestCase {

    private struct SnakeKeyed: Decodable, Equatable {
        let id: Int
        let seriesId: Int
        enum CodingKeys: String, CodingKey { case id; case seriesId = "series_id" }
    }

    private struct CamelOnly: Decodable, Equatable {
        let id: Int
        let seriesId: Int
    }

    private let row = #"{"id":1,"series_id":7}"#.data(using: .utf8)!

    func testConvertFromSnakeCaseBreaksExplicitSnakeCodingKeys() {
        XCTAssertThrowsError(try JSONDecoder.supabase.decode(SnakeKeyed.self, from: row)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
        }
    }

    func testExplicitKeysDecoderReadsExplicitSnakeCodingKeys() throws {
        let decoded = try JSONDecoder.supabaseExplicitKeys.decode(SnakeKeyed.self, from: row)
        XCTAssertEqual(decoded, SnakeKeyed(id: 1, seriesId: 7))
    }

    func testTheTwoDecodersCoverTheTwoModelShapes() throws {
        // `.supabase` is correct for a camelCase-only model, which is the other half of the rule.
        XCTAssertEqual(try JSONDecoder.supabase.decode(CamelOnly.self, from: row).seriesId, 7)
    }

    // MARK: - The real payloads

    /// A `versus_challenges` row exactly as PostgREST returns it, including the microsecond
    /// timestamps `.iso8601` alone rejects.
    private let challengeRow = """
    [{"id":42,"series_id":7,"sport":"nfl","format":"grid","puzzle_id":"grid-nfl-2026-08-04",
      "challenger_id":"aaaa","opponent_id":"bbbb","status":"pending",
      "challenger_score":null,"opponent_score":null,"winner_id":null,
      "challenger_completed_at":null,"opponent_completed_at":null,
      "time_limit_seconds":124,"challenger_started_at":"2026-08-13T10:00:00.123456+00:00",
      "opponent_started_at":null,
      "created_at":"2026-08-13T09:59:00.000001+00:00",
      "expires_at":"2026-08-14T09:59:00+00:00"}]
    """.data(using: .utf8)!

    func testVersusChallengeDecodesThroughTheRepositoryDecoder() throws {
        let rows = try JSONDecoder.supabaseExplicitKeys.decode([VersusChallenge].self, from: challengeRow)
        let c = try XCTUnwrap(rows.first)
        XCTAssertEqual(c.id, 42)
        XCTAssertEqual(c.seriesId, 7)
        XCTAssertEqual(c.format, .grid)
        XCTAssertEqual(c.puzzleId, "grid-nfl-2026-08-04")
        XCTAssertEqual(c.timeLimitSeconds, 124)
        XCTAssertNotNil(c.challengerStartedAt)
        XCTAssertTrue(c.hasStarted(me: "aaaa"))
        XCTAssertFalse(c.hasStarted(me: "bbbb"))
        // Whole-second and microsecond timestamps must both parse (`expires_at` has no fraction).
        XCTAssertEqual(c.expiresAt.timeIntervalSince(c.createdAt), 86_400, accuracy: 1)
    }

    /// A row written before migration 0015 has none of the three new columns. It must still
    /// decode — `DiskCache` has no schema version, so a cached pre-migration payload outlives
    /// the upgrade, and a throw here would empty the tab all over again.
    func testPreMigrationRowDecodesWithDefaults() throws {
        let legacy = """
        [{"id":1,"series_id":1,"sport":"nfl","puzzle_id":"p","challenger_id":"a",
          "opponent_id":"b","status":"pending","challenger_score":null,"opponent_score":null,
          "winner_id":null,"created_at":"2026-07-01T00:00:00+00:00",
          "expires_at":"2026-07-02T00:00:00+00:00"}]
        """.data(using: .utf8)!
        let c = try XCTUnwrap(try JSONDecoder.supabaseExplicitKeys
            .decode([VersusChallenge].self, from: legacy).first)
        XCTAssertEqual(c.format, .keep4)
        XCTAssertEqual(c.timeLimitSeconds, PuzzleFormat.keep4.defaultDuelSeconds)
        XCTAssertNil(c.challengerStartedAt)
    }

    func testVersusSeriesDecodesThroughTheRepositoryDecoder() throws {
        let data = """
        [{"id":7,"user_a":"aaaa","user_b":"bbbb","sport":"nfl","format":"grid",
          "wins_a":3,"wins_b":1,"status":"active"}]
        """.data(using: .utf8)!
        let s = try XCTUnwrap(try JSONDecoder.supabaseExplicitKeys
            .decode([VersusSeries].self, from: data).first)
        XCTAssertEqual(s.format, .grid)
        XCTAssertEqual(s.myWins(me: "aaaa"), 3)
        XCTAssertEqual(s.theirWins(me: "aaaa"), 1)
    }

    /// An unrecognized format must not fail the decode of the whole array — the same
    /// forward-compatibility rule `ClueKind` documents. A shipped build has to survive the
    /// server learning a fourth format.
    func testUnknownFormatFallsBackInsteadOfThrowing() throws {
        let data = """
        [{"id":7,"user_a":"a","user_b":"b","sport":"nfl","format":"overunder",
          "wins_a":0,"wins_b":0,"status":"active"}]
        """.data(using: .utf8)!
        let s = try XCTUnwrap(try JSONDecoder.supabaseExplicitKeys
            .decode([VersusSeries].self, from: data).first)
        XCTAssertEqual(s.format, .keep4)
    }
}
