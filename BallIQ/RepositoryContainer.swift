import SwiftUI

/// Single observable entry point the views depend on. Local stores are the working source
/// (instant, offline); when signed in, `RemoteSync` mirrors progress/rating to Supabase.
@MainActor
final class RepositoryContainer: ObservableObject {
    let puzzles: PuzzleRepository
    let auth: AuthService
    /// Real-stat catalog for Keep4 creation + community puzzles (nil community when local-only).
    let catalog: PlayerSeasonCatalog
    let community: CommunityPuzzleRepository?
    /// Era-adjustment baselines for composable scoring (bundled; empty until the pipeline ships them).
    let baselines: StatBaselines = .loadBundled()

    private let client: SupabaseClient?
    private let localProgress = LocalProgressRepository()
    private let localRating = LocalRatingRepository()
    private var sync: RemoteSync?

    @Published private(set) var progressSnapshot = ProgressSnapshot()
    @Published private(set) var ratings: [Sport: Int] = [:]
    @Published var sportFilter: SportFilter {
        didSet { UserDefaults.standard.set(sportFilter.rawValue, forKey: "sportFilter") }
    }

    init(auth: AuthService, client: SupabaseClient?) {
        self.auth = auth
        self.client = client
        self.puzzles = client.map { RemotePuzzleRepository(client: $0) } ?? LocalPuzzleRepository()
        self.catalog = PlayerSeasonCatalog(client: client)
        self.community = client.map { CommunityPuzzleRepository(client: $0) }
        let raw = UserDefaults.standard.string(forKey: "sportFilter") ?? SportFilter.all.rawValue
        self.sportFilter = SportFilter(rawValue: raw) ?? .all
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
        guard let client, let uid = auth.userID else { sync = nil; return }
        await auth.refreshIfNeeded()
        let mirror = RemoteSync(client: client, userID: uid,
                                localProgress: localProgress, localRating: localRating)
        sync = mirror
        await mirror.pull()
        await refreshFromLocal()
    }

    func handleSignedOut() { sync = nil }

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
    func rating(for sport: Sport) -> Int { ratings[sport] ?? RatingEngine.startingRating }

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
    func complete(format: GameFormatKind, sport: Sport, performance: Double,
                  perfect: Bool, ranked: Bool = true, date: Date = Date()) async -> SessionRewards {
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

        let snap = await localProgress.recordCompletion(awardingXP: xp, date: date)
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

        return SessionRewards(ratingChange: change, xpEarned: xp,
                              newStreak: snap.streak, newLevel: snap.level,
                              leveledUp: snap.level > beforeLevel)
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
        return try await community.create(id: id, authorId: uid, sport: sport,
                                          format: format, title: title, content: content)
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
    }
}
