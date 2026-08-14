import Foundation

/// One row of `my_bot_records()` — the signed-in caller's cumulative record against a single
/// ladder bot, aggregated server-side from `ladder_attempts` (own-read RLS) joined to
/// `ladder_rungs.bot_id`, grouped by bot.
///
/// A bot the player has never attempted has **no row at all** in the array `myBotRecords()`
/// returns — `RosterView` reads that absence as "no record yet", not as a zero record, which
/// matters because a bot they haven't unlocked and a bot they lost to on rung 1 would otherwise
/// both show up as `played: 0`.
///
/// Deliberately camelCase with no explicit `CodingKeys`, decoded through `JSONDecoder.supabase`
/// (`.convertFromSnakeCase`) rather than `.supabaseExplicitKeys` — the same shape as
/// `ArcadeLeaderboardRepository.Row`. Picking the *other* decoder for a model like this one is
/// the safe half of the trap; see `JSONDecoder.supabase`'s doc comment for the outage the
/// opposite mismatch caused, and `RosterTests` for the pinned case.
struct BotRecord: Decodable, Equatable {
    let botId: String
    let played: Int
    let won: Int
    let bestScore: Double
    let bestBotScore: Double
}

/// The record RPC, kept out of `LadderRepository.swift` itself (owned by a concurrent task this
/// session — Task 1 of `prompts/HANDOFF-bot-characters.md`) as an extension in its own file.
extension LadderRepository {
    /// The caller's record against every bot they've faced. A signed-out caller legitimately
    /// gets `[]` — `my_bot_records` is `security definer` scoped to `auth.uid()`, and the roster
    /// stays browsable signed out, just not attributable to anyone.
    ///
    /// **Why this takes `auth` instead of just being `self.client.rpc(...)`.** Every repository
    /// in this codebase (`LadderRepository` included) keeps its `SupabaseClient` `private` —
    /// there is no accessor, by design, so a repo's networking can't be called around. That's the
    /// right default, but it means an extension declared in a *different file* — the shape this
    /// task was asked to use, so as not to touch `LadderRepository.swift` while another agent is
    /// mid-edit on it — has no way to reach the app's one already-authenticated client either.
    /// Rather than fork that privacy or reach into `RepositoryContainer` (also off-limits this
    /// session), this borrows the exact bootstrap `RepositoryContainer.make` already does —
    /// `client?.tokenProvider = auth.tokenBox` — for a second, thin `SupabaseClient` pointed at
    /// the same `SupabaseConfig.shared` and the same signed-in user's token. `TokenBox` is a
    /// shared, thread-safe holder (see `AuthService.swift`), so this never duplicates auth state,
    /// only the lightweight HTTP-client object that reads it.
    ///
    /// If `LadderRepository.client` is ever loosened to `internal`, this should call it directly
    /// and drop the `auth` parameter — noted in the Task 3 handoff report as the preferred
    /// long-term shape.
    func myBotRecords(auth: AuthService) async -> [BotRecord] {
        guard let client = SupabaseClient() else { return [] }
        // `AuthService` is `@MainActor`; this function isn't, so the cross-actor read is explicit.
        client.tokenProvider = await auth.tokenBox
        struct NoArgs: Encodable {}
        guard let data = try? await client.rpc("my_bot_records", args: NoArgs()) else { return [] }
        return (try? JSONDecoder.supabase.decode([BotRecord].self, from: data)) ?? []
    }
}
