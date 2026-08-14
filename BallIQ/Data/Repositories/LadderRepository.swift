import Foundation

/// The bot ladder's server side, which is deliberately almost nothing: two world-readable
/// content tables, one progress row, and one write RPC.
///
/// **No round trip happens during play.** The bot is solved on-device by `BotSolver` from the
/// rung's `bot_skill`/`seed`, so once the ladder and the board are cached a whole rung is
/// playable offline. That is the entire reason the ladder can deliver a live-feeling opponent
/// without any realtime infrastructure.
final class LadderRepository {
    private let client: SupabaseClient
    /// `LadderRung`/`LadderBot`/`LadderProgress` all use explicit snake_case `CodingKeys`, so
    /// they must not go through `.supabase`'s `.convertFromSnakeCase` — see that decoder's doc
    /// comment for the silent outage this exact mismatch caused in Versus.
    private let rowDecoder: JSONDecoder = .supabaseExplicitKeys

    /// Short on purpose, and shorter than it first was.
    ///
    /// This started at a week, copying `RemotePuzzleRepository.playerNameIndex` — but that cache
    /// holds a 90 KB name index, and this one holds **36 rows**. The saving was negligible and
    /// the cost was a whole class of bug: any content change (a reseed, a new column) stayed
    /// invisible on device for up to a week and read as a decode failure. It bit twice in one
    /// afternoon — first when the character columns landed, then again when the names did, both
    /// times looking like the model was broken when the cache was simply old.
    ///
    /// An hour keeps the ladder instant on a warm launch and fully playable on a plane (the
    /// stale fallback below has no TTL at all), while making a content change land the same day
    /// rather than the same week. Version the keys below only for a shape change that a stale
    /// payload could not survive decoding at all.
    private static let contentTTL: TimeInterval = 3_600
    /// **Bump these whenever the shape of a rung or a bot changes.** `DiskCache` has no version
    /// field and the TTL above is the only expiry, so a client that already cached the old shape
    /// keeps serving it for a week and the new columns silently read as their defaults — which
    /// looks exactly like a decode bug. Caught live: after the character columns landed, every
    /// bot rendered in the default electric/`consistent` colourway because the cached roster
    /// predated `style` and `palette`. Same lever, same reason, as
    /// `RemotePuzzleRepository.playerNameIndex`'s `-v2-` key.
    private static let rungsKey = "ladder-rungs-v3"
    private static let botsKey = "ladder-bots-v3"

    init(client: SupabaseClient) { self.client = client }

    /// Every rung, ascending. Cached; a failed fetch falls back to any stale copy before
    /// giving up, because a stale ladder is still a completely playable one.
    func rungs() async -> [LadderRung] {
        if let entry = await DiskCache.read([LadderRung].self, key: Self.rungsKey),
           Date().timeIntervalSince(entry.writtenAt) < Self.contentTTL, !entry.value.isEmpty {
            return entry.value
        }
        let fresh: [LadderRung] = (try? await client.select("ladder_rungs", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "rung"),
        ], decoder: rowDecoder)) ?? []
        if !fresh.isEmpty {
            await DiskCache.write(fresh, key: Self.rungsKey)
            return fresh
        }
        return await DiskCache.read([LadderRung].self, key: Self.rungsKey)?.value ?? []
    }

    func bots() async -> [String: LadderBot] {
        if let entry = await DiskCache.read([LadderBot].self, key: Self.botsKey),
           Date().timeIntervalSince(entry.writtenAt) < Self.contentTTL, !entry.value.isEmpty {
            return Dictionary(uniqueKeysWithValues: entry.value.map { ($0.id, $0) })
        }
        let fresh: [LadderBot] = (try? await client.select("bots", query: [
            URLQueryItem(name: "select", value: "*"),
        ], decoder: rowDecoder)) ?? []
        if !fresh.isEmpty {
            await DiskCache.write(fresh, key: Self.botsKey)
            return Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        }
        let stale = await DiskCache.read([LadderBot].self, key: Self.botsKey)?.value ?? []
        return Dictionary(uniqueKeysWithValues: stale.map { ($0.id, $0) })
    }

    /// Where this player has got to. `ladder_progress` is own-read only, so a signed-out caller
    /// legitimately gets `.none` — the ladder is still browsable, just not playable.
    func progress(userID: String) async -> LadderProgress {
        let rows: [LadderProgress] = (try? await client.select("ladder_progress", query: [
            URLQueryItem(name: "select", value: "highest_rung"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "limit", value: "1"),
        ], decoder: rowDecoder)) ?? []
        return rows.first ?? .none
    }

    /// Records an attempt and returns the player's new high-water rung.
    ///
    /// Returns nil on failure, which the caller must treat as "the attempt didn't count" rather
    /// than "the player lost" — the local result screen has already told them what happened.
    @discardableResult
    func submitAttempt(rung: Int, score: Double, botScore: Double,
                       won: Bool, elapsedMs: Int) async -> Int? {
        struct Args: Encodable {
            let pRung: Int; let pScore: Double; let pBotScore: Double
            let pWon: Bool; let pElapsedMs: Int
            enum CodingKeys: String, CodingKey {
                case pRung = "p_rung", pScore = "p_score", pBotScore = "p_bot_score"
                case pWon = "p_won", pElapsedMs = "p_elapsed_ms"
            }
        }
        guard let data = try? await client.rpc("submit_ladder_attempt",
            args: Args(pRung: rung, pScore: score, pBotScore: botScore,
                       pWon: won, pElapsedMs: elapsedMs)) else { return nil }
        return try? JSONDecoder().decode(Int.self, from: data)
    }

    /// The exact board a rung names. Same generic by-id fetch Versus uses.
    func puzzle<T: Decodable>(_ type: T.Type, id: String) async -> T? {
        let rows: [LadderContentEnvelope<T>]? = try? await client.select("puzzles", query: [
            URLQueryItem(name: "select", value: "content"),
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "limit", value: "1"),
        ], decoder: JSONDecoder())
        return rows?.first?.content
    }
}

/// `{ "content": … }` — file scope because Swift can't nest a generic type in a generic function.
private struct LadderContentEnvelope<C: Decodable>: Decodable { let content: C }

/// Who won a rung.
///
/// Ties go to the **player**, which is the opposite of the Versus rule and deliberately so: a
/// bot is not a person whose feelings the tiebreak has to be fair to, and a dead heat against
/// the machine that just matched you is a win worth having. Speed is not the tiebreak here
/// either — the bot's pacing is synthetic, so racing it would be racing a formula.
enum LadderOutcome {
    static func playerWon(playerScore: Double, botScore: Double) -> Bool {
        playerScore >= botScore
    }
}
