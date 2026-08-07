import Foundation

/// The prompts Playbook offers *after* first run, once the player has earned the right to be
/// asked — "moments" rather than onboarding steps.
///
/// ## Why this layer exists
///
/// `OnboardingView` is deliberately three screens: pick a sport, learn K4C4, play it, then the
/// account ask. That's the right shape — everything else would be friction before anything has
/// proved worth the friction. The cost is that the three things which actually make the app
/// *social* end up with nowhere to live except Profile, where most people never go:
/// `claimUsernameCard` is at the top of it, `favoriteTeamsCard` is the **ninth card down**, and
/// Friends is a push from there.
///
/// So they're never *offered*. The app has exactly one proactive nudge today — Home's
/// `pushPrimerCard` — and it works precisely because it waits for a streak to exist before it
/// asks to protect one. This generalises that: one prompt, at one earned moment, then silence.
///
/// ## The rules, and why they're here rather than in a view
///
/// Same split as `HomeDailyLoop` and `ActivationState`: the "which prompt, if any" decision is
/// pure arithmetic over a context struct, so it's unit-testable without SwiftUI, and the view
/// (`MomentSheet`) only renders whatever it's handed.
enum Moment: Equatable, Identifiable {
    /// You've played enough to want your name on it. Also the gate for everything social —
    /// `sendRequest(toUsername:)` is the only way to add a friend, so a nameless account is
    /// unaddable.
    case claimUsername
    /// You keep playing this sport; say who you ride with. Carries the sport it's asking about.
    case favoriteTeam(Sport)
    /// You have a name and a streak and nobody to beat.
    case addFriend

    var id: String { analyticsID }

    /// Stable identity for both the UserDefaults bookkeeping keys and the `moment` analytics
    /// property. Treat these as schema — the same rule `AnalyticsEvent` and `OnboardingStep`
    /// follow — and note that `favoriteTeam` deliberately collapses **all** sports onto one id:
    /// the cooldown and show-cap govern "we asked about a favorite team", not "we asked about
    /// the NBA", so a player can't be asked five times by playing five sports.
    var analyticsID: String {
        switch self {
        case .claimUsername:  return "claim_username"
        case .favoriteTeam:   return "favorite_team"
        case .addFriend:      return "add_friend"
        }
    }

    /// Priority when more than one is eligible. Fixed, and the order matters: friends can't find
    /// you without a username, so asking for a friend first would offer something that doesn't
    /// work yet.
    var priority: Int {
        switch self {
        case .claimUsername: return 0
        case .favoriteTeam:  return 1
        case .addFriend:     return 2
        }
    }
}

/// What fired the evaluation. Lands in `moment_shown.properties->>'trigger'`, so a warehouse
/// query can tell "we caught them coming back" apart from "we caught them finishing a game" —
/// which is the first thing worth knowing about a prompt layer.
enum MomentTrigger: String {
    /// The app came to the foreground (including a next-day return).
    case foreground = "foreground"
    /// A game's `fullScreenCover` just dismissed. Never *during* — see `MomentPresenter`.
    case postGame   = "post_game"
}

/// Everything the engine is allowed to look at. Built once per evaluation by
/// `MomentPresenter` from `RepositoryContainer` + the career log; a struct rather than a pile of
/// arguments so a test can state a whole player situation in one literal.
struct MomentContext: Equatable {
    var hasOnboarded = false
    /// `ActivationState.has(.firstGameCompleted)` — nothing is offered to someone who has never
    /// finished a game, whatever their other counters say.
    var hasCompletedFirstGame = false
    var isSignedIn = false
    /// Whole local days since install (`ActivationState.AppOpen.dayIndex`).
    var dayIndex = 0
    /// Total finished sessions, from the career log.
    var gamesPlayed = 0
    /// Finished sessions per sport, same source. Only sports with a `hasTeams` entry can ever
    /// produce a `favoriteTeam` moment.
    var gamesBySport: [Sport: Int] = [:]
    var streak = 0
    var hasUsername = false
    /// Sports that already have a favorite set (`FavoriteTeams.teams.keys`).
    var sportsWithFavorite: Set<Sport> = []
    var acceptedFriends = 0
    /// Whether Home is about to offer the streak-reminder primer (`HomeView.pushPrimerCard`).
    ///
    /// That card is itself an ask, and it predates this layer — so it wins, and moments stay
    /// silent while it's live. Without this the two would stack: a player who just finished their
    /// first game would meet the notification card *and* a sheet on the same screen, which is
    /// precisely the "one ask, then silence" rule this whole file exists to enforce, broken by
    /// the one prompt that isn't routed through it.
    var pushPrimerPending = false

    /// Property bag for `moment_shown`. Kept to the dimensions a funnel query actually slices
    /// by — the whole context would be noise in a flat string column.
    func properties(moment: Moment, trigger: MomentTrigger) -> [String: String] {
        var props = ["moment": moment.analyticsID,
                     "trigger": trigger.rawValue,
                     "games_played": "\(gamesPlayed)",
                     "day_index": "\(dayIndex)"]
        if case .favoriteTeam(let sport) = moment { props["sport"] = sport.rawValue }
        return props
    }
}

/// Install-scoped bookkeeping for what's been asked and when.
///
/// Injectable `UserDefaults` for exactly the reason `ActivationState` documents: BallIQ's unit
/// tests are *hosted* (they run inside the real app process), so a test writing these keys
/// through `.standard` would land in the real app container and leave the next manual launch
/// believing it had already been prompted.
struct MomentState {
    /// A moment retires for good after this many shows, whatever the player did about it —
    /// two asks is the line between a nudge and nagging.
    static let maxShows = 2
    /// Hard floor between *any* two moments, so a player who finishes three games in one evening
    /// meets one prompt, not three.
    static let cooldown: TimeInterval = 48 * 3600

    private enum Key {
        static let lastShown = "moments.lastShownAt"
        static func shown(_ moment: Moment) -> String { "moments.shown.\(moment.analyticsID)" }
        static func satisfied(_ moment: Moment) -> String { "moments.satisfied.\(moment.analyticsID)" }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reading

    func showCount(_ moment: Moment) -> Int { defaults.integer(forKey: Key.shown(moment)) }

    /// Whether the player actually did the thing. Set by `markSatisfied` at the completion site
    /// rather than inferred, because the live signal (`identity.username != nil`) can also become
    /// true via a path this layer never touched — a sync from another device, or Profile's own
    /// card. Both are fine reasons to stop asking; `eligible` checks the live state too.
    func isSatisfied(_ moment: Moment) -> Bool { defaults.bool(forKey: Key.satisfied(moment)) }

    /// Retired = asked enough, or already done. Never asked again either way.
    func isRetired(_ moment: Moment) -> Bool {
        isSatisfied(moment) || showCount(moment) >= Self.maxShows
    }

    func lastShownAt() -> Date? { defaults.object(forKey: Key.lastShown) as? Date }

    /// True when enough time has passed since the last moment of *any* kind. A negative interval
    /// (device clock rolled backwards) reads as "not yet" rather than opening the gate, which is
    /// the conservative direction for a prompt.
    func cooldownElapsed(now: Date = Date()) -> Bool {
        guard let last = lastShownAt() else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown
    }

    // MARK: - Writing

    /// Records a presentation: bumps this moment's counter and re-arms the global cooldown.
    func markShown(_ moment: Moment, now: Date = Date()) {
        defaults.set(showCount(moment) + 1, forKey: Key.shown(moment))
        defaults.set(now, forKey: Key.lastShown)
    }

    /// The player did the thing — retire this moment permanently.
    func markSatisfied(_ moment: Moment) {
        defaults.set(true, forKey: Key.satisfied(moment))
    }
}

/// Picks at most one moment for a given situation. Pure: no UserDefaults reads of its own beyond
/// the `state` it's handed, no clock beyond the `now` it's given, no SwiftUI.
enum MomentEngine {

    /// The highest-priority eligible moment, or nil — which is the answer most of the time, and
    /// deliberately so.
    ///
    /// Ordering is by `Moment.priority`, not by "which trigger fired": a player who is eligible
    /// for all three gets asked for a username first, because the other two don't fully work
    /// without one.
    static func next(context: MomentContext, state: MomentState,
                     now: Date = Date()) -> Moment? {
        guard context.hasOnboarded, context.hasCompletedFirstGame else { return nil }
        guard !context.pushPrimerPending else { return nil }
        guard state.cooldownElapsed(now: now) else { return nil }
        return candidates(context: context)
            .filter { !state.isRetired($0) }
            .min { $0.priority < $1.priority }
    }

    /// Every moment whose *situational* conditions hold, ignoring cooldown/retirement. Split out
    /// so tests can check "would this situation qualify at all" separately from "is it allowed to
    /// fire right now", which are two different bugs.
    static func candidates(context: MomentContext) -> [Moment] {
        var out: [Moment] = []
        if qualifiesForUsername(context) { out.append(.claimUsername) }
        if let sport = favoriteTeamSport(context) { out.append(.favoriteTeam(sport)) }
        if qualifiesForFriend(context) { out.append(.addFriend) }
        return out
    }

    /// Games completed before we ask for a name. Five is a session or two — enough that the
    /// player has a record worth signing, not so many that they've already hit Versus and been
    /// turned away for having no username.
    static let usernameGameThreshold = 5
    /// Games in one sport before we ask who they ride with. Three says "this is your sport"
    /// without waiting for a habit.
    static let favoriteTeamGameThreshold = 3
    /// The fallback trigger for friends, for a player who never hits a 7-day streak.
    static let friendGameThreshold = 10
    /// Streak that earns the friend ask — the same number `ReviewPrompter` treats as a pride
    /// moment, and for the same reason.
    static let friendStreakThreshold = 7

    /// Fires on volume **or** on the return itself: `dayIndex >= 1` means they came back on a
    /// later calendar day, which is the strongest signal this install has that the app stuck.
    /// Signed-out players qualify too — the sheet's CTA is sign-in, and a username is the thing
    /// an account is *for* here.
    private static func qualifiesForUsername(_ context: MomentContext) -> Bool {
        guard !context.hasUsername else { return false }
        return context.gamesPlayed >= usernameGameThreshold || context.dayIndex >= 1
    }

    /// The sport they've played most, among those that have teams, have no favorite yet, and are
    /// past the threshold. Ties break by `Sport.allCases` order so the choice is deterministic
    /// (a coin-flip here would make the test suite flaky and the prompt feel arbitrary).
    ///
    /// Signed-in only: `favorite_teams` is a `profiles` column, so there is nowhere to put the
    /// answer otherwise, and asking a question we can't store is worse than not asking.
    private static func favoriteTeamSport(_ context: MomentContext) -> Sport? {
        guard context.isSignedIn else { return nil }
        return Sport.allCases
            .filter { $0.hasTeams }
            .filter { !context.sportsWithFavorite.contains($0) }
            .filter { (context.gamesBySport[$0] ?? 0) >= favoriteTeamGameThreshold }
            .max { lhs, rhs in (context.gamesBySport[lhs] ?? 0) < (context.gamesBySport[rhs] ?? 0) }
    }

    /// Needs a username, because `SocialRepository.sendRequest(toUsername:)` is the only way in
    /// and a friend has to be able to type *something*. Zero accepted friends only — this is the
    /// empty-graph prompt, not a "grow your network" one.
    private static func qualifiesForFriend(_ context: MomentContext) -> Bool {
        guard context.isSignedIn, context.hasUsername, context.acceptedFriends == 0 else {
            return false
        }
        return context.streak >= friendStreakThreshold || context.gamesPlayed >= friendGameThreshold
    }
}
