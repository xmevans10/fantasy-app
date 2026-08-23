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
    /// Rating seasons — the 8-week competitive ladder (M5 Phase F). Nil when local-only.
    let seasons: SeasonRepository?
    let versus: VersusRepository?
    /// The bot ladder (M22) — opponents that exist without a social graph. Nil when local-only.
    let ladder: LadderRepository?
    let dailyDraftBoard: DailyDraftLeaderboardRepository?
    /// Weekly arcade boards for Over/Under + Grid (backlog #5). Nil when local-only.
    let arcadeBoard: ArcadeLeaderboardRepository?
    /// Friends graph + public profiles (M19). Nil when local-only — social is server-only.
    let social: SocialRepository?
    /// Era-adjustment baselines for composable scoring (bundled; empty until the pipeline ships them).
    let baselines: StatBaselines = .loadBundled()
    /// StoreKit 2 product catalog + purchase/restore (M5). `entitlements`, `products` and
    /// `productLoadState` below mirror its published state so views only ever read
    /// `RepositoryContainer`, never this directly.
    let store: StoreService

    private let client: SupabaseClient?
    /// First-party funnel events (M15). Nil when local-only; every call is fire-and-forget.
    private let analytics: AnalyticsClient?
    private let localProgress = LocalProgressRepository()
    private let localRating = LocalRatingRepository()
    private let localSeasonRating = LocalSeasonRatingRepository()
    /// The career game log — see `GameResult`. Local-first because the app is fully playable
    /// signed out; the server copy is a mirror for cross-device restore, not the source of truth.
    let gameLog = LocalGameLogRepository()
    private var sync: RemoteSync?
    private var pendingDeviceToken: String?
    private var storeCancellables = Set<AnyCancellable>()

    @Published private(set) var progressSnapshot = ProgressSnapshot()
    @Published private(set) var ratings: [Sport: Int] = [:]
    /// The active 8-week rating season (M5 Phase F), fetched from `current_rating_season()`.
    /// Nil offline / between seasons; drives the SEASON scope on Leagues.
    @Published private(set) var currentSeason: RatingSeason?
    /// The signed-in user's earned end-of-season badges (peak tier per season/sport), newest first.
    @Published private(set) var seasonBadges: [SeasonBadge] = []
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
    /// How many friendships are actually established (M21) — the signal behind the `addFriend`
    /// moment, which is an empty-graph prompt and must not fire at someone who already has
    /// people. Comes free: `refreshFriendBadge()` already fetches *every* edge to count the
    /// pending ones, so this is one more `filter` over a list we're holding, not a new request.
    @Published private(set) var acceptedFriends = 0
    /// Open Versus challenges I haven't played yet — the tab badge, and the explicit stopgap
    /// while APNs pushes for `versus_challenge` are stubbed. Refreshed on sign-in sync, on
    /// foreground (`ContentView`'s scenePhase watcher), and after any Versus mutation below —
    /// no polling timer, just reuse of the existing pending/active fetch.
    @Published private(set) var openVersusChallenges = 0
    /// What the current user can access (Pro/packs) — the union of the on-device StoreKit read
    /// (`store.entitlements`, instant but only ever reflects what's local) and the server's
    /// verified `entitlements` table (`serverEntitlements`, synced on sign-in — the belt to the
    /// device read's suspenders, covering reinstalls/other devices). Either source proving
    /// entitlement is enough; neither alone is treated as more authoritative than the other.
    @Published private(set) var entitlements: Entitlements = .free
    private var deviceEntitlements: Entitlements = .free
    private var serverEntitlements: Entitlements = .free
    /// The StoreKit catalog and where its load stands, mirrored from `store`.
    ///
    /// These MUST be stored `@Published` state, not computed passthroughs to `store`. SwiftUI
    /// does not forward a nested `ObservableObject`'s changes, so while these were computed the
    /// paywall could not observe a catalog that arrived *while it was on screen*: the fetch
    /// succeeded, `store.products` filled, and `container.objectWillChange` never fired, so the
    /// body was never re-evaluated and the plans never rendered. That is verbatim the Guideline
    /// 2.1(a) rejection of 1.3 build 17 ("The plans did not load"), and it also left the
    /// paywall's "Try again" button doing nothing at all. Covered by
    /// `PaywallProductObservationTests`.
    @Published private(set) var products: [Product] = []
    @Published private(set) var productLoadState: ProductLoadState = .idle
    /// Diagnosis for a failed catalog load — shown on the paywall in DEBUG builds only.
    @Published private(set) var productLoadDiagnostic: String?
    @Published var sportFilter: SportFilter {
        didSet { UserDefaults.standard.set(sportFilter.rawValue, forKey: "sportFilter") }
    }

    /// `store` is injectable purely as a test seam: `StoreService()` starts a launch-time
    /// catalog fetch, which makes "the paywall opened with an empty catalog" — the exact state
    /// that got 1.3 rejected — impossible to set up deterministically in a test. The test-only
    /// `StoreService(fetchStub:)` init does no launch fetch, so a test can start genuinely cold.
    /// (`nil` rather than a defaulted `StoreService()` because a default argument is evaluated
    /// in a nonisolated context, and `StoreService` is `@MainActor`.)
    init(auth: AuthService, client: SupabaseClient?, store: StoreService? = nil) {
        self.auth = auth
        self.client = client
        self.store = store ?? StoreService()
        self.puzzles = client.map { RemotePuzzleRepository(client: $0) } ?? LocalPuzzleRepository()
        self.catalog = PlayerSeasonCatalog(client: client)
        self.community = client.map { CommunityPuzzleRepository(client: $0) }
        self.cohorts = client.map { CohortRepository(client: $0) }
        self.seasons = client.map { SeasonRepository(client: $0) }
        self.versus = client.map { VersusRepository(client: $0) }
        self.ladder = client.map { LadderRepository(client: $0) }
        self.dailyDraftBoard = client.map { DailyDraftLeaderboardRepository(client: $0) }
        self.arcadeBoard = client.map { ArcadeLeaderboardRepository(client: $0) }
        self.social = client.map { SocialRepository(client: $0) }
        self.analytics = client.map { AnalyticsClient(client: $0) }
        let raw = UserDefaults.standard.string(forKey: "sportFilter") ?? SportFilter.all.rawValue
        self.sportFilter = SportFilter(rawValue: raw) ?? .all
        self.store.$entitlements.sink { [weak self] value in
            guard let self else { return }
            self.deviceEntitlements = value
            self.recomputeEntitlements()
        }.store(in: &storeCancellables)
        // Seed from `store` first: it may already have a catalog (its own init starts a launch
        // fetch), and a sink only delivers what happens next.
        self.products = self.store.products
        self.productLoadState = self.store.productLoadState
        self.store.$products
            .sink { [weak self] in self?.products = $0 }
            .store(in: &storeCancellables)
        self.store.$productLoadState
            .sink { [weak self] state in
                guard let self else { return }
                let wasFailed = self.productLoadState == .failed
                self.productLoadState = state
                // Only on the transition into `.failed`, so a retry loop doesn't spam the table.
                if state == .failed, !wasFailed { self.reportProductLoadFailure() }
            }
            .store(in: &storeCancellables)
        self.store.$lastLoadDiagnostic
            .sink { [weak self] in self?.productLoadDiagnostic = $0 }
            .store(in: &storeCancellables)
    }

    private func recomputeEntitlements() {
        entitlements = Entitlements(
            isPro: deviceEntitlements.isPro || serverEntitlements.isPro || DebugLaunch.forcePro,
            unlockedPacks: deviceEntitlements.unlockedPacks.union(serverEntitlements.unlockedPacks),
            isAdmin: isAdmin)
    }

    /// Wires auth + optional Supabase client (nil → local-only). Used at launch and in previews.
    static func make(client: SupabaseClient? = SupabaseClient(),
                     store: StoreService? = nil) -> RepositoryContainer {
        let auth = AuthService(client: client)
        client?.tokenProvider = auth.tokenBox
        return RepositoryContainer(auth: auth, client: client, store: store)
    }

    /// Load persisted local state on launch, then sync if already signed in.
    func bootstrap() async {
        await refreshFromLocal()
        await refreshCurrentSeason()
        await syncIfSignedIn()
    }

    /// Fetch the active rating season (server-defined). No-op local-only. Safe to call for guests —
    /// it just populates the SEASON surface; season-rating writes still require a signed-in user.
    func refreshCurrentSeason() async {
        currentSeason = await seasons?.current()
    }

    /// Whether `identity`, `favoriteTeams` and `acceptedFriends` reflect the server yet.
    ///
    /// Anything that *asks the user for something they might already have* has to wait for this.
    /// The moment layer is the first such reader: `identity.username` is nil both for a player who
    /// has never claimed a name and for one whose profile simply hasn't been pulled yet, and
    /// prompting the second to claim the name they already own is the worst version of this
    /// feature. Signed-out sessions are loaded by definition — there is nothing to fetch.
    var isProfileLoaded: Bool { !isSignedIn || didSyncProfile }
    @Published private(set) var didSyncProfile = false

    /// Build the sync mirror for the current user and reconcile remote → local.
    func syncIfSignedIn() async {
        guard let client, let uid = auth.userID else { sync = nil; isAdmin = false; return }
        await auth.refreshIfNeeded()
        adoptLocalData(for: uid)
        let mirror = RemoteSync(client: client, userID: uid,
                                localProgress: localProgress, localRating: localRating,
                                localSeasonRating: localSeasonRating, gameLog: gameLog)
        sync = mirror
        // `pull` now also backfills any device-local (guest-era) sessions the server is missing.
        if let reason = await mirror.pull() {
            track(.gameLogSyncFailed, ["reason": reason, "op": "backfill"])
        }
        if currentSeason == nil { await refreshCurrentSeason() }
        if let season = currentSeason {
            await mirror.pullSeasonRatings(seasonID: season.id)
            seasonBadges = await seasons?.badges(userID: uid) ?? []
        }
        await refreshFromLocal()
        await pushPendingDeviceTokenIfNeeded()
        isAdmin = await community?.isAdmin(userID: uid) ?? false
        favoriteTeams = await loadFavoriteTeams()
        identity = await loadIdentity()
        await refreshFriendBadge()
        await refreshVersusBadge()
        await resubmitTodaysDailyDraftIfNeeded()
        serverEntitlements = await mirror.pullEntitlements()
        recomputeEntitlements()
        // Set last, and only on the path that actually populated the profile fields above.
        didSyncProfile = true
    }

    /// Fire-and-forget push of a Daily Draft official score to `daily_draft_scores`.
    /// Server-side first-write-wins mirrors `DailyDraftStore.recordIfFirst`, so calling this
    /// again with the same day (a retry, or a resubmit on sign-in) is always safe.
    func submitDailyDraftScore(day: String, stored: DailyDraftStore.StoredResult) async {
        guard let dailyDraftBoard, auth.userID != nil else { return }
        await dailyDraftBoard.submit(day: day, stored: stored)
    }

    /// Fire-and-forget post of a finished arcade run to this week's board. Signed-out runs
    /// simply don't post — the caller still records the local high score either way, and the
    /// board ranks each user's weekly best server-side, so reposts are harmless.
    func submitArcadeScore(game: ArcadeLeaderboardRepository.Game, sport: Sport, score: Int) async {
        guard let arcadeBoard, let uid = auth.userID else { return }
        await arcadeBoard.submit(userID: uid, game: game, sport: sport, score: score)
    }

    /// One Grid attempt for the crowd-rarity log (`grid_guesses`).
    struct GridGuessLog: Encodable {
        let puzzleDay: String
        let sport: String
        let cellIndex: Int
        let guessName: String
        let correct: Bool
        let userId: String
    }

    /// One row of `grid_guess_stats`: how many players picked `guessName` for `cellIndex`,
    /// out of `cellTotal` correct picks in that cell.
    struct GridCellPickStats: Decodable {
        let cellIndex: Int
        let guessName: String
        let picks: Int
        let cellTotal: Int
    }

    /// Fire-and-forget crowd-rarity log of a finished Grid run's attempts. Signed-out /
    /// local-only sessions skip silently — the stats are a community aggregate, not progress.
    func logGridGuesses(day: String, sport: Sport, attempts: [(cell: Int, name: String, correct: Bool)]) async {
        guard let client, let uid = auth.userID, !attempts.isEmpty else { return }
        let rows = attempts.map {
            GridGuessLog(puzzleDay: day, sport: sport.rawValue, cellIndex: $0.cell,
                         guessName: $0.name, correct: $0.correct, userId: uid)
        }
        try? await client.insert("grid_guesses", values: rows)
    }

    /// Per-cell pick distribution for one day's Grid ("X% picked this"). Empty when
    /// local-only, offline, or nobody has played yet.
    func gridGuessStats(day: String, sport: Sport) async -> [GridCellPickStats] {
        guard let client else { return [] }
        struct Args: Encodable { let pSport: String, pDay: String }
        guard let data = try? await client.rpc("grid_guess_stats", args: Args(pSport: sport.rawValue, pDay: day)),
              let rows = try? JSONDecoder.supabase.decode([GridCellPickStats].self, from: data) else { return [] }
        return rows
    }

    /// Offline/late-sign-in recovery: if today has a locally locked-in official run, push it.
    /// A run that already reached the server is a no-op server-side.
    private func resubmitTodaysDailyDraftIfNeeded() async {
        let day = OverUnderRoundGenerator.dayString(Date())
        guard let stored = DailyDraftStore().officialResult(for: day) else { return }
        await submitDailyDraftScore(day: day, stored: stored)
    }

    // MARK: - Account deletion (App Store Guideline 5.1.1(v))

    enum AccountDeletionError: LocalizedError {
        case notSignedIn
        case serverUnavailable

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "You're not signed in."
            case .serverUnavailable:
                return "We couldn't reach the server. Your account has not been deleted — "
                     + "please check your connection and try again."
            }
        }
    }

    /// Permanently deletes the signed-in user's account and every trace of it, server and device.
    ///
    /// Ordering matters and is deliberate:
    /// 1. The avatar object goes first, through the Storage API — the `auth.users` cascade covers
    ///    every `public.*` row but not Storage, and deleting the `storage.objects` row from SQL
    ///    alone would leave the file orphaned. A failure here is **non-fatal**: a stranded image
    ///    must never block a user from exercising their right to delete, and
    ///    `delete_own_account()` clears the row regardless.
    /// 2. `delete_own_account()` (security definer, keyed on `auth.uid()`) removes the auth row;
    ///    every table cascades from it. A failure here **aborts** — nothing local has been
    ///    touched yet, so the user still has an intact, working account and can simply retry.
    ///    Wiping the device first would strand them signed-in-but-empty on a server row that
    ///    still exists.
    /// 3. Only once the server has confirmed do we wipe the device and sign out.
    func deleteAccount() async throws {
        guard let client, let uid = auth.userID else { throw AccountDeletionError.notSignedIn }

        // The token has to be valid for `auth.uid()` to resolve inside the function; an expired
        // one would surface as "not authenticated" rather than as the auth problem it is.
        await auth.refreshIfNeeded()

        try? await client.deleteObject(bucket: "avatars", path: "\(uid)/avatar.jpg")

        struct NoArgs: Encodable {}
        do {
            try await client.rpc("delete_own_account", args: NoArgs())
        } catch {
            throw AccountDeletionError.serverUnavailable
        }

        wipeLocalUserData()
        auth.signOut()
        handleSignedOut()
        progressSnapshot = ProgressSnapshot()
        ratings = [:]
        seasonBadges = []
        await refreshFromLocal()
    }

    /// `UserDefaults` key naming which user the on-device progress belongs to. Nil means it's
    /// guest data that nobody has claimed yet.
    static let localDataOwnerKey = "localDataOwnerUserID"

    /// Hands the device's local progress to `uid`, wiping it first if it belongs to someone else.
    ///
    /// Local rating/progress/streak keys are not namespaced by user, and `RemoteSync.mergeRating`
    /// is a `max` of local and remote. That combination is deliberate for guest → first account:
    /// a player who racks up a 1231 rating before signing up keeps it. But it cannot tell that
    /// case apart from signing in as a *different* account on the same device, where the same
    /// `max` silently hands the previous user's rating to the new one — reported 2026-07-30,
    /// where a brand-new account opened showing the previous user's 1231 NFL rating.
    ///
    /// Recording an owner separates the two: no owner means unclaimed guest data and it migrates
    /// as before; a different owner means this is someone else's device state and it goes.
    func adoptLocalData(for uid: String) {
        let defaults = UserDefaults.standard
        if let owner = defaults.string(forKey: Self.localDataOwnerKey), owner != uid {
            // Not `purgingCache: true`: the disk cache holds *content* — puzzles, boards, crests —
            // not the previous user's data, so dropping it on a switch buys no privacy and costs
            // a full refetch. Deletion still purges it, where "remove every trace" is the point.
            wipeLocalUserData(purgingCache: false)
        }
        defaults.set(uid, forKey: Self.localDataOwnerKey)
    }

    /// Clears every on-device trace of the account. None of these keys are namespaced by user id,
    /// so without this a deleted account's streak, rating and scores would simply reappear for
    /// whoever signs in next on the same device.
    private func wipeLocalUserData(purgingCache: Bool = true) {
        let prefixes = LocalProgressRepository.persistedKeyPrefixes
            + LocalRatingRepository.persistedKeyPrefixes
            + LocalSeasonRatingRepository.persistedKeyPrefixes
            + DailyDraftStore.persistedKeyPrefixes
            + LocalOverUnderStore.persistedKeyPrefixes
            + ["sportFilter", Self.localDataOwnerKey]

        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where prefixes.contains(where: { key == $0 || key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        sportFilter = .all
        if purgingCache { DiskCache.purge() }
        // The career log lives in Application Support, which neither the UserDefaults sweep above
        // nor `DiskCache.purge()` (Caches) reaches. Without this, a deleted account leaves its
        // complete play history on disk — an App Store 5.1.1(v) problem, not just a bug.
        LocalGameLogRepository.wipe()
        Task { [gameLog] in await gameLog.invalidate() }
    }

    func handleSignedOut() {
        sync = nil; isAdmin = false; favoriteTeams = .empty
        identity = .empty; pendingFriendRequests = 0; acceptedFriends = 0; openVersusChallenges = 0
        didSyncProfile = false
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

    /// This user's rating in the active season for `sport` — the soft-reset seed if unplayed, or
    /// their moved value otherwise. Nil when there's no active season. Synchronous (reads the local
    /// season store) so the SEASON hero renders without a fetch; the board's rank comes from the RPC.
    func seasonRating(for sport: Sport) -> Int? {
        guard let season = currentSeason else { return nil }
        let seed = SeasonSeed.seed(fromAllTime: ratings[sport] ?? RatingEngine.startingRating)
        return localSeasonRating.rating(seasonID: season.id, sport: sport, seed: seed)
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

    /// Everything a finished session knows that the rating math doesn't need — score, accuracy,
    /// timing and the per-format extras that power the career stats.
    ///
    /// Defaulted end-to-end so a call site that hasn't been migrated still compiles and still
    /// records a (thinner) row, which is what let the six game views be updated independently
    /// rather than in one atomic change across the whole app.
    struct SessionDetail {
        var mode: PlayMode = .daily
        var score = 0
        var maxScore = 0
        var correct = 0
        var attempted = 0
        /// Set at the view's existing `track(.gameStarted)` site; `nil` simply means untimed.
        var startedAt: Date?
        var details = GameResultDetails()

        init(mode: PlayMode = .daily, score: Int = 0, maxScore: Int = 0,
             correct: Int = 0, attempted: Int = 0, startedAt: Date? = nil,
             details: GameResultDetails = GameResultDetails()) {
            self.mode = mode
            self.score = score
            self.maxScore = maxScore
            self.correct = correct
            self.attempted = attempted
            self.startedAt = startedAt
            self.details = details
        }
    }

    /// Record a finished session: award XP, advance streak, apply rating, then push to the server.
    ///
    /// `ranked` defaults to true (daily play). Community puzzles pass `ranked: false`:
    /// XP and streak still count, but competitive rating is untouched (and no rating
    /// history is pushed), so easy user-made puzzles can't farm the ladder.
    ///
    /// `detail` additionally writes the session to the career log (`GameResult`). It is defaulted
    /// rather than required so this stayed an additive change — see `SessionDetail`.
    func complete(format: GameFormatKind, sport: Sport, performance: Double, perfect: Bool,
                  puzzleID: String, ranked: Bool = true, date: Date = Date(),
                  detail: SessionDetail = SessionDetail()) async -> SessionRewards {
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
        let outcome = GameOutcome(format: format, sport: sport, performance: performance)
        if ranked {
            change = await localRating.apply(outcome, date: date)
        } else {
            let current = await localRating.rating(for: sport)
            change = RatingChange(old: current, new: current)   // unranked: no rating movement
        }

        // Season ladder (M5 Phase F): same Elo engine, on a parallel per-season row seeded from a
        // soft-reset snapshot of the all-time rating. Only when ranked and a season is active; the
        // all-time rating above is untouched by this.
        var seasonMove: (seasonID: Int, rating: Int, peak: Int)?
        if ranked, let season = currentSeason {
            let seed = SeasonSeed.seed(fromAllTime: change.old)
            let seasonChange = localSeasonRating.apply(outcome, seasonID: season.id, seed: seed, date: date)
            let peak = localSeasonRating.peak(seasonID: season.id, sport: sport, seed: seed)
            seasonMove = (season.id, seasonChange.new, peak)
        }

        progressSnapshot = snap
        await refreshRatings()

        // Push to the server in the background (no-op when signed out / offline / unranked rating).
        if let sync {
            Task { await sync.pushProgress(snap)
                   if ranked {
                       await sync.pushRating(sport: sport, rating: change.new, recordHistory: true)
                   }
                   if let move = seasonMove {
                       await sync.pushSeasonRating(seasonID: move.seasonID, sport: sport,
                                                   rating: move.rating, peak: move.peak)
                   } }
        }
        // Weekly league XP mirrors lifetime XP earning (both ranked and unranked sessions count).
        if let cohorts {
            Task { await cohorts.bumpWeeklyXP(xp) }
        }

        // Career log. Written here — after `progressSnapshot`/`refreshRatings()` and before the
        // analytics event — so rating before/after, XP and streak are all the settled values for
        // this session rather than a mix of pre- and post-state.
        await recordGameResult(format: format, sport: sport, performance: performance,
                               perfect: perfect, puzzleID: puzzleID, ranked: ranked, date: date,
                               ratingBefore: change.old, ratingAfter: change.new,
                               xpEarned: xp, streakAfter: snap.streak, detail: detail)

        track(.gameCompleted, ["format": format.rawValue, "sport": sport.rawValue,
                               "ranked": "\(ranked)", "perfect": "\(perfect)"])

        return SessionRewards(ratingChange: change, xpEarned: xp,
                              newStreak: snap.streak, newLevel: snap.level,
                              leveledUp: snap.level > beforeLevel)
    }

    /// Record a session in the career log **without** awarding XP, advancing the streak, or moving
    /// rating.
    ///
    /// Exists for Grid practice, which is re-rollable on demand and so must stay reward-free — but
    /// there's no reason those reps shouldn't count toward accuracy and volume. `PlayMode`'s
    /// `countsForRecords` keeps them out of personal bests.
    func logSession(format: GameFormatKind, sport: Sport, performance: Double, perfect: Bool,
                    puzzleID: String, date: Date = Date(), detail: SessionDetail) async {
        let current = await localRating.rating(for: sport)
        await recordGameResult(format: format, sport: sport, performance: performance,
                               perfect: perfect, puzzleID: puzzleID, ranked: false, date: date,
                               ratingBefore: current, ratingAfter: current,
                               xpEarned: 0, streakAfter: progressSnapshot.streak, detail: detail)
    }

    /// Builds the `GameResult`, appends it locally, and mirrors it to the server in the background.
    /// The local write is awaited (a stat read immediately after a game must see it); the push is
    /// not (it no-ops when signed out, and a career log that only works online would be empty for
    /// most first sessions).
    private func recordGameResult(format: GameFormatKind, sport: Sport, performance: Double,
                                  perfect: Bool, puzzleID: String, ranked: Bool, date: Date,
                                  ratingBefore: Int, ratingAfter: Int, xpEarned: Int,
                                  streakAfter: Int, detail: SessionDetail) async {
        let durationMs = detail.startedAt.map {
            max(0, Int(date.timeIntervalSince($0) * 1000))
        }
        // The universal speed multiplier (M25), applied in exactly one place so every format
        // gets it and none of them implement it twice (AGENTS.md §4). Timers are gone; this is
        // what replaced them. Points only — `performance` is deliberately passed through
        // untouched, because it feeds the rating engine and is `0...1`-checked in Postgres.
        let score = SpeedMultiplier.points(detail.score, startedAt: detail.startedAt,
                                           finishedAt: date, kind: format)
        let result = GameResult(playedAt: date, format: format, sport: sport, mode: detail.mode,
                                ranked: ranked, perfect: perfect, performance: performance,
                                score: score, maxScore: detail.maxScore,
                                correct: detail.correct, attempted: detail.attempted,
                                durationMs: durationMs,
                                ratingBefore: ratingBefore, ratingAfter: ratingAfter,
                                xpEarned: xpEarned, streakAfter: streakAfter,
                                puzzleID: puzzleID, details: detail.details)
        await gameLog.append(result)
        if let sync {
            // Local append above is the source of truth, so a failed mirror never costs the player
            // their history on THIS device — but it does cost them on the next one, which is
            // exactly the kind of silent loss that has to be observable from the outside.
            Task { [weak self] in
                if let reason = await sync.pushGameResult(result) {
                    await MainActor.run { self?.track(.gameLogSyncFailed,
                                                      ["reason": reason, "op": "single"]) }
                }
            }
        }
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

    /// Starts a duel against a **user id**, in `format`.
    ///
    /// The id overload is the primary one. Every entry point used to round-trip through a
    /// username string, which disabled the CHALLENGE button for anyone who hadn't claimed a
    /// name — a bottleneck entirely independent of the friends graph, and one of the reasons
    /// this feature had produced zero completed duels. Surfaces that already hold an id
    /// (a public profile, a cohort standings row, a friends list) must call this one.
    ///
    /// The board is chosen server-side; nothing about it is passed from here.
    @discardableResult
    func createVersusChallenge(userID opponentID: String, sport: Sport,
                               format: PuzzleFormat) async throws -> Int {
        guard let versus else { throw CommunityError.unavailable }
        guard let uid = auth.userID else { throw CommunityError.notSignedIn }
        guard opponentID != uid else { throw VersusError.cannotChallengeSelf }
        let challengeID = try await versus.createChallenge(opponentID: opponentID, sport: sport,
                                                           format: format)
        track(.challengeStarted, ["format": format.rawValue, "sport": sport.rawValue,
                                  "source": "versus"])
        await refreshVersusBadge()   // the new duel is itself unplayed by me
        return challengeID
    }

    /// Username overload, for the one surface that genuinely only has a typed name (the manual
    /// entry field in the New Duel sheet). Resolves to an id and defers to the method above.
    @discardableResult
    func createVersusChallenge(username: String, sport: Sport,
                               format: PuzzleFormat) async throws -> Int {
        guard let versus else { throw CommunityError.unavailable }
        guard auth.userID != nil else { throw CommunityError.notSignedIn }
        guard let opponentID = await versus.findOpponent(username: username) else {
            throw VersusError.opponentNotFound
        }
        return try await createVersusChallenge(userID: opponentID, sport: sport, format: format)
    }

    /// Starts this player's clock on a duel and returns the session a game view runs on.
    ///
    /// Returns nil when the duel can't be opened (closed, expired, or offline) — the caller
    /// should refresh its list rather than retry.
    func startVersusDuel(_ row: VersusChallengeRow) async -> DuelSession? {
        guard let versus, let me = auth.userID else { return nil }
        guard let seconds = try? await versus.startChallenge(id: row.challenge.id) else { return nil }
        return DuelSession(challengeID: row.challenge.id,
                           format: row.challenge.format,
                           boardID: row.challenge.puzzleId,
                           opponentUserID: row.challenge.opponentID(me: me),
                           opponentName: row.opponentUsername,
                           secondsRemaining: seconds)
    }

    /// Records the caller's score on a duel (called from each game view's `finish()`).
    ///
    /// One entry point for both kinds of opponent, so the three game views stay identical: a
    /// human duel posts to `versus_challenges`, a ladder rung posts to `ladder_attempts`, and
    /// neither game view has to know which it is playing.
    func submitDuelResult(_ session: DuelSession, performance: Double,
                          elapsed: TimeInterval) async {
        if let ladder = session.ladder {
            // `session.boardID`, not `rung.puzzleId`: the rung names its pool's ordinal-0 board,
            // and recording that for every attempt would make "which boards has this player seen"
            // permanently answer "only the first one" — which is the question pools exist to
            // answer, so this is the whole feature and not a detail.
            await submitLadderAttempt(ladder, puzzleID: session.boardID,
                                      performance: performance, elapsed: elapsed)
        } else {
            await submitVersusResult(challengeID: session.challengeID, performance: performance)
        }
    }

    /// Records the caller's score on a **human** duel.
    func submitVersusResult(challengeID: Int, performance: Double) async {
        await versus?.submitResult(challengeID: challengeID, score: performance)
        await refreshVersusBadge()
    }

    // MARK: - Bot ladder (M22)

    /// How far up the ladder this player has climbed. Refreshed after every attempt so the
    /// ladder list is honest without a re-fetch on every appearance.
    @Published private(set) var ladderProgress: LadderProgress = .none

    /// Solves the rung's board with `BotSolver` and hands back a ready-to-play session.
    ///
    /// The bot's entire run is computed here, before the board is ever on screen — which is
    /// exactly why the ladder needs no transport: "playing alongside" the bot is replaying
    /// `run.beats` against the clock. Nil when the rung's board can't be fetched.
    /// - Parameter board: which board of the rung's pool to play. Nil asks the server for the next
    ///   one the player hasn't seen, which is what every caller wants except a rematch, where the
    ///   result screen has already resolved the board it is offering.
    func startLadderRung(_ row: LadderRungRow, board: LadderBoard? = nil) async -> DuelBoard? {
        guard let ladder else { return nil }
        let rung = row.rung
        let limit = TimeInterval(rung.timeLimitSeconds)
        // A rung is a difficulty, not a board: retrying must not hand back the board whose answers
        // the player already knows. The seed travels WITH the board, so the bot doesn't replay an
        // identical decision pattern on the new one either.
        let served: LadderBoard
        if let board { served = board } else { served = await ladder.nextBoard(for: rung) }
        let seed = served.generatorSeed

        func session(_ run: BotRun) -> DuelSession {
            DuelSession(challengeID: rung.rung, format: rung.mode, boardID: served.puzzleId,
                        opponentUserID: nil, opponentName: row.bot.name,
                        secondsRemaining: rung.timeLimitSeconds,
                        ladder: LadderRunSession(rung: rung, bot: row.bot, run: run))
        }

        switch rung.mode {
        case .keep4:
            guard let p = await ladder.puzzle(Keep4Puzzle.self, id: served.puzzleId) else { return nil }
            return .keep4(session(BotSolver.playKeep4(p, skill: rung.botSkill, seed: seed, timeLimit: limit,
                                                 style: row.bot.style)), p)
        case .grid:
            guard let p = await ladder.puzzle(GridPuzzle.self, id: served.puzzleId) else { return nil }
            return .grid(session(BotSolver.playGrid(p, skill: rung.botSkill, seed: seed, timeLimit: limit,
                                                 style: row.bot.style)), p)
        case .whoami:
            guard let p = await ladder.puzzle(WhoAmIPuzzle.self, id: served.puzzleId) else { return nil }
            return .whoami(session(BotSolver.playWhoAmI(p, skill: rung.botSkill, seed: seed, timeLimit: limit,
                                                 style: row.bot.style)), p)
        // No rung is minted in journeyman mode today (`ladder_rungs.mode` still refuses the
        // value server-side), but the arm is real rather than a `return nil`: the ladder's
        // 30-rung curve is a server-side artifact, and the client should be able to play
        // whatever it is served the day that curve is re-cut.
        case .journeyman:
            guard let p = await ladder.puzzle(JourneymanPuzzle.self, id: served.puzzleId) else { return nil }
            return .journeyman(session(BotSolver.playJourneyman(p, skill: rung.botSkill, seed: seed,
                                                 timeLimit: limit, style: row.bot.style)), p)
        }
    }

    /// Starts a **human** duel: starts this player's clock server-side, then fetches the exact
    /// board it names. Order matters — a server that refuses (duel resolved, expired, not ours)
    /// must cost nothing, and the reverse order would leave the clock running on a failed fetch.
    func startVersusBoard(_ row: VersusChallengeRow) async -> DuelBoard? {
        guard let versus, let session = await startVersusDuel(row) else { return nil }
        let id = row.challenge.puzzleId
        switch row.challenge.format {
        case .keep4:
            guard let p = await versus.puzzle(Keep4Puzzle.self, id: id) else { return nil }
            return .keep4(session, p)
        case .grid:
            guard let p = await versus.puzzle(GridPuzzle.self, id: id) else { return nil }
            return .grid(session, p)
        case .whoami:
            guard let p = await versus.puzzle(WhoAmIPuzzle.self, id: id) else { return nil }
            return .whoami(session, p)
        case .journeyman:
            guard let p = await versus.puzzle(JourneymanPuzzle.self, id: id) else { return nil }
            return .journeyman(session, p)
        }
    }

    /// Posts a finished rung. The ladder pays **XP and rank only, never the solo rating** —
    /// the same rule the Versus info sheet states ("Versus games never affect your rating"),
    /// which is why this goes through `logSession` rather than `complete(...)`.
    private func submitLadderAttempt(_ run: LadderRunSession, puzzleID: String,
                                     performance: Double, elapsed: TimeInterval) async {
        guard let ladder else { return }
        // Speed counts now (see `LadderOutcome`), so the recorded result needs both clocks. The
        // stored `score` stays the raw `performance`: `ladder_attempts.score` is checked 0...1 and
        // is the corpus human ghost duels will be built from, so it has to keep meaning "how well
        // was this board played" rather than "how well, adjusted for a bot's pace on one rung".
        let won = LadderOutcome.playerWon(playerScore: performance, botScore: run.run.performance,
                                          playerElapsed: elapsed, botElapsed: run.run.elapsed,
                                          limit: TimeInterval(run.rung.timeLimitSeconds))
        if let newHigh = await ladder.submitAttempt(
            rung: run.rung.rung, puzzleID: puzzleID, score: performance,
            botScore: run.run.performance,
            won: won, elapsedMs: max(0, Int(elapsed * 1000))) {
            ladderProgress = LadderProgress(highestRung: newHigh)
        }
        track(.challengeStarted, ["format": run.rung.mode.rawValue,
                                  "sport": run.rung.sport.rawValue,
                                  "source": "ladder",
                                  "rung": String(run.rung.rung),
                                  "won": String(won)])
    }

    /// The ladder list: every rung, joined to its bot, with each one's lock state.
    func ladderRows() async -> [LadderRungRow] {
        guard let ladder else { return [] }
        async let rungsFetch = ladder.rungs()
        async let botsFetch = ladder.bots()
        let (rungs, bots) = await (rungsFetch, botsFetch)
        if let uid = auth.userID { ladderProgress = await ladder.progress(userID: uid) }
        return rungs.compactMap { rung in
            guard let bot = bots[rung.botId] else { return nil }
            return LadderRungRow(rung: rung, bot: bot, state: ladderProgress.state(of: rung.rung))
        }
    }

    /// Recounts open duels I haven't played yet. Call after sign-in sync, on foreground, and
    /// after any Versus mutation so the tab badge stays honest without a realtime channel
    /// (mirrors `refreshFriendBadge()`).
    func refreshVersusBadge() async {
        guard let versus, let uid = auth.userID else { openVersusChallenges = 0; return }
        let rows = await versus.openChallenges(userID: uid)
        openVersusChallenges = VersusChallengeRow.unplayedCount(rows, me: uid)
    }

    // MARK: - Push (device token + per-category settings)

    /// Called from `BallIQApp` when `AppDelegate` gets an APNs token. Stashed until the user is
    /// signed in (the `device_tokens` row needs a `user_id`), then pushed via `syncIfSignedIn()`.
    func registerDeviceToken(_ token: String) {
        pendingDeviceToken = token
        Task { await pushPendingDeviceTokenIfNeeded() }
    }

    /// Which APNs environment this build's tokens are minted for.
    ///
    /// APNs runs two separate hosts and a token is only valid on the one that issued it. The
    /// server cannot infer this — it has to be recorded per token — and getting it wrong is
    /// silent: the send is accepted, then rejected with `BadDeviceToken`, which reads exactly
    /// like a corrupt token. That is what made 100% of this app's pushes fail for months.
    ///
    /// `DEBUG` is the right discriminator rather than a proxy for one: Xcode's Debug build uses
    /// the development provisioning profile (`aps-environment: development`), while archives —
    /// including TestFlight, which is *not* sandbox — are Release and get production.
    private static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    private func pushPendingDeviceTokenIfNeeded() async {
        guard let client, let uid = auth.userID, let token = pendingDeviceToken else { return }
        struct Row: Encodable {
            let userId: String; let token: String; let platform: String; let utcOffsetMinutes: Int
            let apnsEnvironment: String
        }
        let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
        try? await client.upsert("device_tokens",
            values: Row(userId: uid, token: token, platform: "ios", utcOffsetMinutes: offsetMinutes,
                        apnsEnvironment: Self.apnsEnvironment),
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
            let friendRequest: Bool, dailyDrop: Bool, engagement: Bool
        }
        try? await client.upsert("notification_settings",
            values: Row(userId: uid, streakAtRisk: settings.streakAtRisk, leaguePosition: settings.leaguePosition,
                       versusChallenge: settings.versusChallenge, seasonEnd: settings.seasonEnd,
                       friendRequest: settings.friendRequest, dailyDrop: settings.dailyDrop,
                       engagement: settings.engagement),
            onConflict: "user_id")
    }

    // MARK: - Store (M5 — StoreKit 2 monetization)

    // `products`/`productLoadState` are declared with the other `@Published` state above and
    // fed by sinks in `init` — see the note there for why they are mirrored rather than
    // computed off `store`.

    /// Re-fetch the catalog. The paywall calls this whenever it opens with an empty catalog:
    /// the launch-time load can lose a cold-start race against the network, and before this
    /// existed that left the paywall permanently empty for the session (the Guideline 2.1(a)
    /// rejection of 1.3 build 16 — see `StoreService.loadProducts`).
    func reloadProducts() async { await store.loadProducts() }

    /// Records WHY the catalog failed, so a paywall with no plans is diagnosable from the
    /// outside. `receipt` distinguishes a TestFlight/App-Review run (`sandbox`) from the live
    /// store (`production`) and from a build that has no receipt at all (`none`) — a
    /// development build installed from Xcode, where a local `.storekit` configuration may be
    /// standing in for the App Store and a failure means something entirely different.
    private func reportProductLoadFailure() {
        let receipt: String
        switch Bundle.main.appStoreReceiptURL?.lastPathComponent {
        case "sandboxReceipt": receipt = "sandbox"
        case .some(let name) where !name.isEmpty: receipt = "production"
        default: receipt = "none"
        }
        track(.productLoadFailed, [
            "reason": store.lastLoadDiagnostic ?? "unknown",
            "receipt": receipt,
            "attempts": String(store.productFetchAttempts),
        ])
    }

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

    /// Uploads a JPEG profile photo to the `avatars` bucket at `{uid}/avatar.jpg` (upsert, so
    /// re-uploads overwrite in place) and returns its public URL. `IdentityEditorSheet` treats
    /// the return value exactly like a preset emoji — just another string for `saveIdentity`'s
    /// `avatar` param — and every render site (`AvatarView`) tells the two apart by URL prefix.
    /// A cache-busting query param is appended so `AsyncImage` doesn't keep serving the old
    /// photo bytes from the same overwritten path.
    func uploadAvatarPhoto(_ data: Data) async throws -> String {
        guard let client, let uid = auth.userID else { throw SupabaseError.notConfigured }
        let path = "\(uid)/avatar.jpg"
        try await client.uploadObject(bucket: "avatars", path: path, data: data, contentType: "image/jpeg")
        let bust = Int(Date().timeIntervalSince1970)
        return "\(client.publicObjectURL(bucket: "avatars", path: path).absoluteString)?t=\(bust)"
    }

    /// Recounts incoming pending friend requests (cheap: one filtered select). Call after
    /// any friends mutation so badges stay honest without a realtime channel.
    func refreshFriendBadge() async {
        guard let social, let uid = auth.userID else {
            pendingFriendRequests = 0
            acceptedFriends = 0
            return
        }
        let edges = await social.edges(me: uid)
        pendingFriendRequests = edges.filter { $0.isIncomingPending(me: uid) }.count
        acceptedFriends = edges.filter(\.isAccepted).count
    }
}
