import Foundation

/// Mirrors local progress + rating to Supabase. Local stores stay the working source (instant,
/// offline); this pulls on sign-in/launch and pushes after each completed game.
/// Sync rule: progress is server-authoritative once a row exists (multi-device); rating is `max`
/// merged; on first sign-in with no server row, local "guest" progress is pushed up (migration).
final class RemoteSync {
    private let client: SupabaseClient
    private let userID: String
    private let localProgress: LocalProgressRepository
    private let localRating: LocalRatingRepository
    private let localSeasonRating: LocalSeasonRatingRepository
    private let gameLog: LocalGameLogRepository

    init(client: SupabaseClient, userID: String,
         localProgress: LocalProgressRepository, localRating: LocalRatingRepository,
         localSeasonRating: LocalSeasonRatingRepository,
         gameLog: LocalGameLogRepository) {
        self.client = client
        self.userID = userID
        self.localProgress = localProgress
        self.localRating = localRating
        self.localSeasonRating = localSeasonRating
        self.gameLog = gameLog
    }

    static func mergeRating(local: Int, remote: Int?) -> Int { max(local, remote ?? local) }

    // MARK: - Pull (reconcile remote → local)

    func pull() async {
        await pullProgress()
        await pullRatings()
        await pullGameLog()
    }

    /// Server-verified entitlement state (M5 Phase B — written only by the
    /// `app-store-notifications` Edge Function). RLS already scopes rows to the caller, so no
    /// explicit `user_id` filter is needed, matching `pullProgress`/`pullRatings`'s own pattern.
    func pullEntitlements() async -> Entitlements {
        struct Row: Decodable { let productId: String; let status: String }
        let rows: [Row] = (try? await client.select(
            "entitlements", query: [item("select", "product_id,status")])) ?? []
        var isPro = false
        var packs: Set<String> = []
        for row in rows where row.status == "active" {
            guard let product = StoreProduct(rawValue: row.productId) else { continue }
            if product.isSubscription { isPro = true } else { packs.insert(product.rawValue) }
        }
        return Entitlements(isPro: isPro, unlockedPacks: packs)
    }

    private func pullProgress() async {
        struct Row: Decodable { let streak: Int; let xp: Int; let lastPlayedDay: String? }
        do {
            let rows: [Row] = try await client.select(
                "progress", query: [item("select", "streak,xp,last_played_day")])
            if let r = rows.first {
                localProgress.overwrite(ProgressSnapshot(streak: r.streak, xp: r.xp,
                                                         lastPlayedDay: r.lastPlayedDay ?? ""))
            } else {
                await pushProgress(localProgress.load())   // migrate guest progress up
            }
        } catch {
            // offline / error → keep local as-is
        }
    }

    private func pullRatings() async {
        struct Row: Decodable { let sport: String; let rating: Int }
        let remote: [Row] = (try? await client.select(
            "ratings", query: [item("select", "sport,rating")])) ?? []
        let remoteMap = Dictionary(remote.map { ($0.sport, $0.rating) }, uniquingKeysWith: { a, _ in a })
        for sport in Sport.allCases {
            let local = await localRating.rating(for: sport)
            let merged = Self.mergeRating(local: local, remote: remoteMap[sport.rawValue])
            localRating.setRating(merged, for: sport)
            if remoteMap[sport.rawValue] != merged {
                await pushRating(sport: sport, rating: merged, recordHistory: false)
            }
        }
    }

    // MARK: - Push

    func pushProgress(_ snapshot: ProgressSnapshot) async {
        struct Up: Encodable { let userId: String; let streak: Int; let xp: Int; let lastPlayedDay: String }
        try? await client.upsert("progress",
            values: Up(userId: userID, streak: snapshot.streak, xp: snapshot.xp,
                       lastPlayedDay: snapshot.lastPlayedDay),
            onConflict: "user_id")
    }

    // MARK: - Career game log

    /// The wire shape of a `GameResult`. Written out rather than making `GameResult` itself carry
    /// `user_id`: the local log is per-device and has no notion of an account, and the server's
    /// column set is allowed to drift from the on-disk one without touching the model.
    private struct GameResultRow: Codable {
        let id: UUID
        let userId: String
        let playedAt: Date
        let format: String
        let sport: String
        let mode: String
        let ranked: Bool
        let perfect: Bool
        let performance: Double
        let score: Int
        let maxScore: Int
        let correct: Int
        let attempted: Int
        let durationMs: Int?
        let ratingBefore: Int
        let ratingAfter: Int
        let xpEarned: Int
        let streakAfter: Int
        let puzzleId: String
        let details: GameResultDetails

        init(_ r: GameResult, userID: String) {
            id = r.id; userId = userID; playedAt = r.playedAt
            format = r.format.rawValue; sport = r.sport.rawValue; mode = r.mode.rawValue
            ranked = r.ranked; perfect = r.perfect; performance = r.performance
            score = r.score; maxScore = r.maxScore
            correct = r.correct; attempted = r.attempted; durationMs = r.durationMs
            ratingBefore = r.ratingBefore; ratingAfter = r.ratingAfter
            xpEarned = r.xpEarned; streakAfter = r.streakAfter
            puzzleId = r.puzzleID; details = r.details
        }

        /// Server row → local model. Unknown enum values (a format this build predates) are
        /// dropped rather than defaulted, so a stale client can't silently miscategorise history.
        func toResult() -> GameResult? {
            guard let format = GameFormatKind(rawValue: format),
                  let sport = Sport(rawValue: sport),
                  let mode = PlayMode(rawValue: mode) else { return nil }
            return GameResult(id: id, playedAt: playedAt, format: format, sport: sport, mode: mode,
                              ranked: ranked, perfect: perfect, performance: performance,
                              score: score, maxScore: maxScore, correct: correct,
                              attempted: attempted, durationMs: durationMs,
                              ratingBefore: ratingBefore, ratingAfter: ratingAfter,
                              xpEarned: xpEarned, streakAfter: streakAfter,
                              puzzleID: puzzleId, details: details)
        }
    }

    /// Mirrors one finished session. `upsert` on the client-generated `id` rather than `insert`
    /// so a retry (offline queue, a re-push after sign-in) can't double-count the session.
    func pushGameResult(_ result: GameResult) async {
        try? await client.upsert("game_results",
                                 values: GameResultRow(result, userID: userID),
                                 onConflict: "id")
    }

    /// Batched variant for backfilling a guest's local history after they sign in.
    func pushGameLog(_ results: [GameResult]) async {
        guard !results.isEmpty else { return }
        try? await client.upsert("game_results",
                                 values: results.map { GameResultRow($0, userID: userID) },
                                 onConflict: "id")
    }

    /// Restores the server copy into the local log.
    ///
    /// This is also what fixes a long-standing gap: `pullRatings` restores only the scalar rating,
    /// so a signed-in user opening the app on a new device had the right number and an empty
    /// history behind it. RLS scopes rows to the caller, so no explicit `user_id` filter is
    /// needed — same pattern as `pullProgress`/`pullRatings`.
    func pullGameLog(limit: Int = 2000) async {
        let rows: [GameResultRow] = (try? await client.select("game_results", query: [
            item("select", "*"),
            item("order", "played_at.desc"),
            item("limit", "\(limit)"),
        ])) ?? []
        let results = rows.compactMap { $0.toResult() }
        guard !results.isEmpty else { return }
        await gameLog.merge(results)
    }

    func pushRating(sport: Sport, rating: Int, recordHistory: Bool) async {
        struct Up: Encodable { let userId: String; let sport: String; let rating: Int }
        try? await client.upsert("ratings",
            values: Up(userId: userID, sport: sport.rawValue, rating: rating),
            onConflict: "user_id,sport")
        if recordHistory {
            struct Hist: Encodable { let userId: String; let sport: String; let rating: Int }
            try? await client.insert("rating_history",
                values: Hist(userId: userID, sport: sport.rawValue, rating: rating))
        }
    }

    // MARK: - Rating seasons (M5 Phase F)

    /// Restore this user's season ratings for the active season on sign-in/launch. Server-authoritative
    /// (server wins) — unlike all-time rating there's no `max`-merge, because the row is keyed by
    /// `season_id`: a brand-new season has no server row, so nothing is restored and the first ranked
    /// game seeds fresh. That's what keeps the soft-reset from being clobbered.
    func pullSeasonRatings(seasonID: Int) async {
        struct Row: Decodable { let sport: String; let rating: Int; let peakRating: Int }
        let rows: [Row] = (try? await client.select("season_ratings", query: [
            item("select", "sport,rating,peak_rating"),
            item("season_id", "eq.\(seasonID)"),
            item("user_id", "eq.\(userID)"),
        ])) ?? []
        for row in rows {
            guard let sport = Sport(rawValue: row.sport) else { continue }
            localSeasonRating.setRating(row.rating, peak: row.peakRating, seasonID: seasonID, sport: sport)
        }
    }

    /// Mirror one season-rating move up to `season_ratings` (RLS pins writes to the active season).
    func pushSeasonRating(seasonID: Int, sport: Sport, rating: Int, peak: Int) async {
        struct Up: Encodable {
            let seasonId: Int; let userId: String; let sport: String
            let rating: Int; let peakRating: Int
        }
        try? await client.upsert("season_ratings",
            values: Up(seasonId: seasonID, userId: userID, sport: sport.rawValue,
                       rating: rating, peakRating: peak),
            onConflict: "season_id,user_id,sport")
    }

    private func item(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }
}
