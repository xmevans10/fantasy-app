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

    init(client: SupabaseClient, userID: String,
         localProgress: LocalProgressRepository, localRating: LocalRatingRepository) {
        self.client = client
        self.userID = userID
        self.localProgress = localProgress
        self.localRating = localRating
    }

    static func mergeRating(local: Int, remote: Int?) -> Int { max(local, remote ?? local) }

    // MARK: - Pull (reconcile remote → local)

    func pull() async {
        await pullProgress()
        await pullRatings()
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

    private func item(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }
}
