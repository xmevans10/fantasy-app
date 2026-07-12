import SwiftUI
import Combine
import StoreKit

/// Single observable entry point the views depend on. Local stores are the working source
/// (instant, offline); when signed in, `RemoteSync` mirrors progress/rating to Supabase.
@MainActor
final class RepositoryContainer: ObservableObject {
    let puzzles: PuzzleRepository
    let auth: AuthService
    /// Real-stat catalog for Keep4 creation + community puzzles (nil community when local-only).
    let catalog: PlayerSeasonCatalog
    let community: CommunityPuzzleRepository?
    let cohorts: CohortRepository?
    let versus: VersusRepository?
    /// Friends graph + public profiles (M19). Nil when local-only — social is server-only.
    let social: SocialRepository?
    /// Era-adjustment baselines for composable scoring (bundled; empty until the pipeline ships them).
    let baselines: StatBaselines = .loadBundled()
    /// StoreKit 2 product catalog + purchase/restore (M5). `entitlements` below mirrors its
    /// published state so views only ever read `RepositoryContainer`, never this directly.
    let store = StoreService()

    private let client: SupabaseClient?
    /// First-party funnel events (M15). Nil when local-only; every call is fire-and-forget.
    private let analytics: AnalyticsClient?
    private let localProgress = LocalProgressRepository()
    private let localRating = LocalRatingRepository()
    private var sync: RemoteSync?
    private var pendingDeviceToken: String?
    private var storeCancellable: AnyCancellable?

    @Published private(set) var progressSnapshot = ProgressSnapshot()
    @Published private(set) var ratings: [Sport: Int] = [:]
    /// Operator flag (`profiles.is_admin`) — gates the moderation review surface in Profile.
    @Published private(set) var isAdmin = false
    /// One team per sport the user follows (`profiles.favorite_teams`) — cached here (rather
    /// than re-fetched per view) so Home/Browse/Community can synchronously badge a puzzle
    /// whose cards feature the user's team.
    @Published private(set) var favoriteTeams = FavoriteTeams.empty
    /// The signed-in user's own `profiles.username`/`avatar` (M19) — cached like
    /// `favoriteTeams` so Profile renders identity synchronously.
    @Published private(set) var identity = ProfileIdentity.empty
    /// Incoming pending friend-request count (M19) — badge fuel for Profile/Friends entry
    /// points; refreshed on sign-in sync and after any friends mutation via `refreshFriendBadge()`.
    @Published private(set) var pendingFriendRequests = 0
    /// What the current user can access (Pro/packs) — the union of the on-device StoreKit read
    /// (`store.entitlements`, instant but only ever reflects what's local) and the server's
    /// verified `entitlements` table (`serverEntitlements`, synced on sign-in — the belt to the
    /// device read's suspenders, covering reinstalls/other devices). Either source proving
    /// entitlement is enough; neither alone is treated as more authoritative than the other.
    @Published private(set) var entitlements: Entitlements = .free
    private var deviceEntitlements: Entitlements = .free
    private var serverEntitlements: Entitlements = .free
    @Published var sportFilter: SportFilter {
        didSet { UserDefaults.standard.set(sportFilter.rawValue, forKey: "sportFilter") }
    }

    init(auth: AuthService, client: SupabaseClient?) {
        self.auth = auth
        self.client = client
        self.puzzles = client.map { RemotePuzzleRepository(client: $0) } ?? LocalPuzzleRepository()
        self.catalog = PlayerSeasonCatalog(client: client)
        self.community = client.map { CommunityPuzzleRepository(client: $0) }
        self.cohorts = client.map { CohortRepository(client: $0) }
        self.versus = client.map { VersusRepository(client: $0) }
        self.social = client.map { SocialRepository(client: $0) }
        self.analytics = client.map { AnalyticsClient(client: $0) }
        let raw = UserDefaults.standard.string(forKey: "sportFilter") ?? SportFilter.all.rawValue
        self.sportFilter = SportFilter(rawValue: raw) ?? .all
        storeCancellable = store.$entitlements.sink { [weak self] value in
            guard let self else { return }
            self.deviceEntitlements = value
            self.recomputeEntitlements()
        }
    }

    private func recomputeEntitlements() {
        entitlements = Entitlements(
            isPro: deviceEntitlements.isPro || serverEntitlements.isPro,
            unlockedPacks: deviceEntitlements.unlockedPacks.union(serverEntitlements.unlockedPacks),
            isAdmin: isAdmin)
    }

    /// Wires auth + optional Supabase client (nil → local-only). Used at launch and in previews.
    static func make(client: SupabaseClient? = SupabaseClient()) -> RepositoryContainer {
        let auth = AuthService(client: client)
        client?.tokenProvider = auth.tokenBox
        return RepositoryContainer(auth: auth, client: client)
    }

    /// Load persisted local state on launch, then sync if already signed in.
    func bootstrap() async {
        await refreshFromLocal()
        await syncIfSignedIn()
    }

    /// Build the sync mirror for the current user and reconcile remote → local.
    func syncIfSignedIn() async {
        guard let client, let uid = auth.userID else { sync = nil; isAdmin = false; return }
        await auth.refreshIfNeeded()
        let mirror = RemoteSync(client: client, userID: uid,
                                localProgress: localProgress, localRating: localRating)
        sync = mirror
        await mirror.pull()
        await refreshFromLocal()
        await pushPendingDeviceTokenIfNeeded()
        isAdmin = await community?.isAdmin(userID: uid) ?? false
        favoriteTeams = await loadFavoriteTeams()
        identity = await loadIdentity()
        await refreshFriendBadge()
        serverEntitlements = await mirror.pullEntitlements()
        recomputeEntitlements()
    }

    func handleSignedOut() {
        sync = nil; isAdmin = false; favoriteTeams = .empty
        identity = .empty; pendingFriendRequests = 0
        serverEntitlements = .free
        recomputeEntitlements()
    }

    private func refreshFromLocal() async {
        progressSnapshot = await localProgress.load()
        await refreshRatings()
    }

    private func refreshRatings() async {
        var map: [Sport: Int] = [:]
        for sport in Sport.allCases { map[sport] = await localRating.rating(for: sport) }
        ratings = map
    }

    // MARK: - Convenience reads

    var streak: Int { progressSnapshot.streak }
    var xp: Int { progressSnapshot.xp }
    var level: Int { progressSnapshot.level }
    func hasPlayedToday(_ date: Date = Date()) -> Bool { progressSnapshot.hasPlayed(on: date) }
    /// Was this *specific* puzzle (by id) completed today? Distinct from `hasPlayedToday`, which
    /// is "played anything" and still drives streak/first-play XP. Keyed by id rather than just
    /// format+day so a stale completion can't leak onto a different puzzle served under the same
    /// daily slot (e.g. the daily-puzzle content rotating underneath an already-completed flag).
    func hasCompletedToday(puzzleID: String, date: Date = Date()) -> Bool {
        progressSnapshot.hasCompletedToday(puzzleID: puzzleID, on: date)
    }
    func rating(for sport: Sport) -> Int { ratings[sport] ?? RatingEngine.startingRating }
    func ratingHistory(for sport: Sport) async -> [RatingPoint] { await localRating.history(for: sport) }

    // MARK: - Completion

    struct SessionRewards: Equatable {
        let ratingChange: RatingChange
        let xpEarned: Int
        let newStreak: Int
        let newLevel: Int
        let leveledUp: Bool
    }

    /// Record a finished session: award XP, advance streak, apply rating, then push to the server.
    ///
    /// `ranked` defaults to true (daily play). Community puzzles pass `ranked: false`:
    /// XP and streak still count, but competitive rating is untouched (and no rating
    /// history is pushed), so easy user-made puzzles can't farm the ladder.
    func complete(format: GameFormatKind, sport: Sport, performance: Double, perfect: Bool,
                  puzzleID: String, ranked: Bool = true, date: Date = Date()) async -> SessionRewards {
        let before = progressSnapshot
        let firstPlay = !before.hasPlayed(on: date)
        let beforeLevel = before.level

        // Streak this completion will produce (mirrors LocalProgressRepository's math).
        let willStreak: Int = {
            let today = LocalProgressRepository.dayString(date)
            if before.lastPlayedDay == today { return before.streak }
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: date),
               before.lastPlayedDay == LocalProgressRepository.dayString(yesterday) {
                return before.streak + 1
            }
            return 1
        }()

        var xp = format.baseXP
        if perfect { xp += 75 }
        if firstPlay {
            xp += 50                                   // first play of the day
            xp += min(willStreak, 30) * 25             // streak continuation, capped at day 30
        }

        let snap = await localProgress.recordCompletion(format: format, puzzleID: puzzleID,
                                                         awardingXP: xp, date: date)
        let change: RatingChange
        if ranked {
            change = await localRating.apply(
                GameOutcome(format: format, sport: sport, performance: performance), date: date)
        } else {
            let current = await localRating.rating(for: sport)
            change = RatingChange(old: current, new: current)   // unranked: no rating movement
        }

        progressSnapshot = snap
        await refreshRatings()

        // Push to the server in the background (no-op when signed out / offline / unranked rating).
        if let sync {
            Task { await sync.pushProgress(snap)
                   if ranked {
                       await sync.pushRating(sport: sport, rating: change.new, recordHistory: true)
                   } }
        }
        // Weekly league XP mirrors lifetime XP earning (both ranked and unranked sessions count).
        if let cohorts {
            Task { await cohorts.bumpWeeklyXP(xp) }
        }

        track(.gameCompleted, ["format": format.rawValue, "sport": sport.rawValue,
                               "ranked": "\(ranked)", "perfect": "\(perfect)"])

        return SessionRewards(ratingChange: change, xpEarned: xp,
                              newStreak: snap.streak, newLevel: snap.level,
                              leveledUp: snap.level > beforeLevel)
    }

    // MARK: - Analytics (M15 — first-party, fire-and-forget)

    /// Log a funnel event. Never blocks or fails the calling action; no-op when local-only.
    func track(_ event: AnalyticsEvent, _ properties: [String: String] = [:]) {
        analytics?.log(event, properties, userID: auth.userID)
    }

    // MARK: - Community (user-generated puzzles)

    enum CommunityError: Error { case notSignedIn, unavailable }

    var isSignedIn: Bool { auth.userID != nil }

    /// Publish a user-authored puzzle; returns its share id. Requires sign-in + a remote client.
    /// `id` is generated by the caller so it can be baked into `content` (stable blind order).
    func publish<C: Encodable>(id: String, sport: Sport, format: String, title: String,
                               content: C) async throws -> String {
        guard let community else { throw CommunityError.unavailable }
        guard let uid = auth.userID else { throw CommunityError.notSignedIn }
        let shareID = try await community.create(id: id, authorId: uid, sport: sport,
                                                 format: format, title: title, content: content)
        track(.puzzlePublished, ["format": format, "sport": sport.rawValue])
        return shareID
    }

    /// A fresh share id for a new community puzzle.
    func newCommunityID() -> String { CommunityPuzzleRepository.newID() }

    /// Log a community play (best-effort; powers the Popular sort). No-op when signed out.
    func recordCommunityPlay(id: String) async {
        guard let community, let uid = auth.userID else { return }
        await community.recordPlay(id: id, userID: uid)
    }

    func reportCommunity(id: String, reason: String?) async {
        guard let community, let uid = auth.userID else { return }
        await community.report(id: id, userID: uid, reason: reason)
        track(.reportFiled, ["puzzle_id": id])
    }

    // MARK: - Versus (1v1 head-to-head)

    /// Starts a challenge against `username` on today's Keep4 puzzle for `sport`.
    func createVersusChallenge(username: String, sport: Sport) async throws -> Int {
        guard let versus else { throw CommunityError.unavailable }
        guard let uid = auth.userID else { throw CommunityError.notSignedIn }
        guard let opponentID = await versus.findOpponent(username: username) else {
            throw VersusError.opponentNotFound
        }
        guard opponentID != uid else { throw VersusError.cannotChallengeSelf }
        let filter = SportFilter(rawValue: sport.rawValue) ?? .all
        guard let puzzle = await puzzles.keep4Puzzle(for: filter, date: Date()) else {
            throw VersusError.opponentNotFound
        }
        return try await versus.createChallenge(opponentID: opponentID, sport: sport, puzzleID: puzzle.id)
    }

    /// Records the caller's score on a Versus challenge (called from `Keep4GameView.finish()`).
    func submitVersusResult(challengeID: Int, performance: Double) async {
        await versus?.submitResult(challengeID: challengeID, score: performance)
    }

    // MARK: - Push (device token + per-category settings)

    /// Called from `BallIQApp` when `AppDelegate` gets an APNs token. Stashed until the user is
    /// signed in (the `device_tokens` row needs a `user_id`), then pushed via `syncIfSignedIn()`.
    func registerDeviceToken(_ token: String) {
        pendingDeviceToken = token
        Task { await pushPendingDeviceTokenIfNeeded() }
    }

    private func pushPendingDeviceTokenIfNeeded() async {
        guard let client, let uid = auth.userID, let token = pendingDeviceToken else { return }
        struct Row: Encodable {
            let userId: String; let token: String; let platform: String; let utcOffsetMinutes: Int
        }
        let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
        try? await client.upsert("device_tokens",
            values: Row(userId: uid, token: token, platform: "ios", utcOffsetMinutes: offsetMinutes),
            onConflict: "user_id,token")
    }

    func loadNotificationSettings() async -> NotificationSettings {
        guard let client, let uid = auth.userID else { return .allEnabled }
        let items = [URLQueryItem(name: "user_id", value: "eq.\(uid)"), URLQueryItem(name: "limit", value: "1")]
        let rows: [NotificationSettings]? = try? await client.select("notification_settings", query: items)
        return rows?.first ?? .allEnabled
    }

    func saveNotificationSettings(_ settings: NotificationSettings) async {
        guard let client, let uid = auth.userID else { return }
        struct Row: Encodable {
            let userId: String
            let streakAtRisk: Bool, leaguePosition: Bool, versusChallenge: Bool, seasonEnd: Bool
        }
        try? await client.upsert("notification_settings",
            values: Row(userId: uid, streakAtRisk: settings.streakAtRisk, leaguePosition: settings.leaguePosition,
                       versusChallenge: settings.versusChallenge, seasonEnd: settings.seasonEnd),
            onConflict: "user_id")
    }

    // MARK: - Store (M5 — StoreKit 2 monetization)

    var products: [Product] { store.products }
    var isLoadingProducts: Bool { store.isLoadingProducts }

    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let appAccountToken = auth.userID.flatMap(UUID.init(uuidString:))
        let purchased = try await store.purchase(product, appAccountToken: appAccountToken)
        if purchased {
            track(.purchaseCompleted, ["product_id": product.id])
        }
        return purchased
    }

    func restorePurchases() async { await store.restore() }

    // MARK: - Favorite teams

    func loadFavoriteTeams() async -> FavoriteTeams {
        guard let client, let uid = auth.userID else { return .empty }
        struct Row: Decodable { let favoriteTeams: [String: String] }
        let items = [URLQueryItem(name: "id", value: "eq.\(uid)"),
                     URLQueryItem(name: "select", value: "favorite_teams"), URLQueryItem(name: "limit", value: "1")]
        let rows: [Row]? = try? await client.select("profiles", query: items)
        return rows?.first.map { FavoriteTeams(teams: $0.favoriteTeams) } ?? .empty
    }

    func saveFavoriteTeams(_ favoriteTeams: FavoriteTeams) async {
        self.favoriteTeams = favoriteTeams
        guard let client, let uid = auth.userID else { return }
        struct Row: Encodable { let id: String; let favoriteTeams: [String: String] }
        try? await client.upsert("profiles",
            values: Row(id: uid, favoriteTeams: favoriteTeams.teams), onConflict: "id")
    }

    // MARK: - Identity & friends (M19)

    func loadIdentity() async -> ProfileIdentity {
        guard let client, let uid = auth.userID else { return .empty }
        struct Row: Decodable { let username: String?; let avatar: String? }
        let items = [URLQueryItem(name: "id", value: "eq.\(uid)"),
                     URLQueryItem(name: "select", value: "username,avatar"),
                     URLQueryItem(name: "limit", value: "1")]
        let rows: [Row]? = try? await client.select("profiles", query: items)
        return rows?.first.map { ProfileIdentity(username: $0.username, avatar: $0.avatar) } ?? .empty
    }

    /// Saves username/avatar. Throws on failure — `profiles.username` is UNIQUE, so a taken
    /// name surfaces as `SupabaseError.http(status: 409, …)`; callers show "already taken".
    /// On success the published `identity` updates so every surface re-renders at once.
    func saveIdentity(username: String?, avatar: String?) async throws {
        guard let client, let uid = auth.userID else { return }
        struct Row: Encodable { let id: String; let username: String?; let avatar: String? }
        try await client.upsert("profiles",
            values: Row(id: uid, username: username, avatar: avatar), onConflict: "id")
        identity = ProfileIdentity(username: username, avatar: avatar)
    }

    /// Recounts incoming pending friend requests (cheap: one filtered select). Call after
    /// any friends mutation so badges stay honest without a realtime channel.
    func refreshFriendBadge() async {
        guard let social, let uid = auth.userID else { pendingFriendRequests = 0; return }
        let edges = await social.edges(me: uid)
        pendingFriendRequests = edges.filter { $0.isIncomingPending(me: uid) }.count
    }
}
