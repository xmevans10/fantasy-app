import XCTest
@testable import BallIQ

/// The post-onboarding prompt rules: which moment fires, when, and — mostly — when nothing does.
///
/// Everything runs against an injected `UserDefaults` suite for the same reason
/// `ActivationFunnelTests` documents: these tests are *hosted* (they execute inside the real
/// BallIQ.app process), so writing `moments.*` through `.standard` would land in the real app
/// container and leave the next manual launch believing it had already been prompted — which is
/// exactly the state that makes this feature impossible to test by hand afterwards.
final class MomentEngineTests: XCTestCase {

    private let suiteName = "MomentEngineTests"
    private var defaults: UserDefaults!
    private var state: MomentState!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        state = MomentState(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        state = nil
        super.tearDown()
    }

    /// A player who has done enough to qualify for *nothing* — every test below turns exactly one
    /// thing on, so a failure names the condition rather than the fixture.
    private func baseline() -> MomentContext {
        MomentContext(hasOnboarded: true, hasCompletedFirstGame: true, isSignedIn: true,
                      dayIndex: 0, gamesPlayed: 1, gamesBySport: [.nfl: 1], streak: 1,
                      hasUsername: true, sportsWithFavorite: [.nfl], acceptedFriends: 3)
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: - Nothing fires by default

    func testQuietPlayerGetsNothing() {
        XCTAssertNil(MomentEngine.next(context: baseline(), state: state))
    }

    // MARK: - Gates that silence everything

    /// Onboarding has its own username ask (`OnboardingView.finishOrClaimUsername`). A moment
    /// firing underneath it would be the same question twice in ninety seconds.
    func testNothingFiresBeforeOnboardingCompletes() {
        var context = baseline()
        context.hasOnboarded = false
        context.hasUsername = false
        context.gamesPlayed = 20
        XCTAssertNil(MomentEngine.next(context: context, state: state))
    }

    /// `gamesPlayed` can be non-zero from a server backfill on a fresh device; the milestone
    /// can't. Nobody who hasn't finished a game here gets asked for anything.
    func testNothingFiresBeforeFirstGameCompleted() {
        var context = baseline()
        context.hasCompletedFirstGame = false
        context.hasUsername = false
        context.gamesPlayed = 20
        XCTAssertNil(MomentEngine.next(context: context, state: state))
    }

    /// Home's streak-reminder card is itself an ask and it predates this layer, so it wins.
    func testPushPrimerSuppressesEverything() {
        var context = baseline()
        context.hasUsername = false
        context.gamesPlayed = 20
        context.pushPrimerPending = true
        XCTAssertNil(MomentEngine.next(context: context, state: state))

        context.pushPrimerPending = false
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .claimUsername)
    }

    // MARK: - claimUsername

    func testUsernameFiresOnGameVolume() {
        var context = baseline()
        context.hasUsername = false
        context.gamesPlayed = MomentEngine.usernameGameThreshold
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .claimUsername)
    }

    func testUsernameDoesNotFireBelowThresholdOnDayZero() {
        var context = baseline()
        context.hasUsername = false
        context.gamesPlayed = MomentEngine.usernameGameThreshold - 1
        XCTAssertNil(MomentEngine.next(context: context, state: state))
    }

    /// Coming back on a later day is the strongest signal an install gets, so it qualifies on its
    /// own — a two-game player who returned tomorrow is worth more than a five-game bingeer.
    func testUsernameFiresOnReturnVisitRegardlessOfVolume() {
        var context = baseline()
        context.hasUsername = false
        context.gamesPlayed = 1
        context.dayIndex = 1
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .claimUsername)
    }

    /// Signed-out players qualify: the sheet's CTA is sign-in, and a username is what the account
    /// is for here.
    func testUsernameFiresWhileSignedOut() {
        var context = baseline()
        context.isSignedIn = false
        context.hasUsername = false
        context.gamesPlayed = 10
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .claimUsername)
    }

    func testUsernameNeverFiresOnceClaimed() {
        var context = baseline()
        context.gamesPlayed = 50
        context.dayIndex = 9
        XCTAssertNotEqual(MomentEngine.next(context: context, state: state), .claimUsername)
    }

    // MARK: - favoriteTeam

    func testFavoriteTeamFiresForTheMostPlayedEligibleSport() {
        var context = baseline()
        context.sportsWithFavorite = []
        context.gamesBySport = [.nfl: 3, .nba: 7]
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .favoriteTeam(.nba))
    }

    func testFavoriteTeamSkipsSportsThatAlreadyHaveOne() {
        var context = baseline()
        context.sportsWithFavorite = [.nba]
        context.gamesBySport = [.nfl: 3, .nba: 7]
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .favoriteTeam(.nfl))
    }

    /// Tennis's `teamAbbr` is a country code, not a club — there is no team to pick, so it must
    /// never produce this moment however much it's played.
    func testFavoriteTeamNeverFiresForTennis() {
        var context = baseline()
        context.sportsWithFavorite = []
        context.gamesBySport = [.tennis: 40]
        XCTAssertNil(MomentEngine.next(context: context, state: state))
    }

    func testFavoriteTeamRequiresThreeGamesInThatSport() {
        var context = baseline()
        context.sportsWithFavorite = []
        context.gamesBySport = [.nba: MomentEngine.favoriteTeamGameThreshold - 1]
        XCTAssertNil(MomentEngine.next(context: context, state: state))

        context.gamesBySport = [.nba: MomentEngine.favoriteTeamGameThreshold]
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .favoriteTeam(.nba))
    }

    /// `favorite_teams` is a `profiles` column — there is nowhere to put a signed-out answer, and
    /// asking a question we can't store is worse than not asking.
    func testFavoriteTeamRequiresSignIn() {
        var context = baseline()
        context.isSignedIn = false
        context.sportsWithFavorite = []
        context.gamesBySport = [.nba: 10]
        XCTAssertNil(MomentEngine.next(context: context, state: state))
    }

    /// Ties break by `Sport.allCases` order rather than dictionary order, which is unspecified —
    /// otherwise this prompt would pick a different sport on different runs.
    func testFavoriteTeamTieBreaksDeterministically() {
        var context = baseline()
        context.sportsWithFavorite = []
        context.gamesBySport = [.nfl: 5, .nba: 5, .baseball: 5]
        for _ in 0..<20 {
            XCTAssertEqual(MomentEngine.next(context: context, state: state), .favoriteTeam(.nfl))
        }
    }

    // MARK: - addFriend

    func testFriendFiresOnStreak() {
        var context = baseline()
        context.acceptedFriends = 0
        context.streak = MomentEngine.friendStreakThreshold
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .addFriend)
    }

    func testFriendFiresOnGameVolume() {
        var context = baseline()
        context.acceptedFriends = 0
        context.gamesPlayed = MomentEngine.friendGameThreshold
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .addFriend)
    }

    /// `sendRequest(toUsername:)` is the only way into the friends graph, so a nameless account
    /// can't be added by anyone — offering the ask would offer something that doesn't work.
    func testFriendRequiresAUsername() {
        var context = baseline()
        context.acceptedFriends = 0
        context.hasUsername = false
        context.gamesPlayed = 50
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .claimUsername)
    }

    /// This is the empty-graph prompt, not a "grow your network" one.
    func testFriendNeverFiresForSomeoneWhoHasFriends() {
        var context = baseline()
        context.acceptedFriends = 1
        context.streak = 30
        context.gamesPlayed = 200
        XCTAssertNil(MomentEngine.next(context: context, state: state))
    }

    // MARK: - Priority

    /// All three eligible at once. Username wins because the other two don't fully work without
    /// it: friends can't find you, and the team badge is stored against a profile.
    func testUsernameOutranksEverythingElse() {
        var context = baseline()
        context.hasUsername = false
        context.gamesPlayed = 50
        context.streak = 30
        context.acceptedFriends = 0
        context.sportsWithFavorite = []
        context.gamesBySport = [.nba: 20]
        XCTAssertEqual(MomentEngine.candidates(context: context).count, 2)
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .claimUsername)
    }

    func testFavoriteTeamOutranksFriend() {
        var context = baseline()
        context.acceptedFriends = 0
        context.streak = 30
        context.sportsWithFavorite = []
        context.gamesBySport = [.nba: 20]
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .favoriteTeam(.nba))
    }

    // MARK: - Cooldown, caps, retirement

    func testCooldownBlocksASecondMomentInsideTwoDays() {
        var context = baseline()
        context.sportsWithFavorite = []
        context.gamesBySport = [.nba: 20]
        let shown = date("2026-08-01T12:00:00Z")
        state.markShown(.claimUsername, now: shown)

        XCTAssertNil(MomentEngine.next(context: context, state: state,
                                       now: shown.addingTimeInterval(47 * 3600)))
        XCTAssertEqual(MomentEngine.next(context: context, state: state,
                                         now: shown.addingTimeInterval(48 * 3600)),
                       .favoriteTeam(.nba))
    }

    /// A device clock dragged backwards must read as "not yet", not as an open gate — the
    /// conservative direction for a prompt.
    func testBackwardsClockDoesNotOpenTheCooldown() {
        var context = baseline()
        context.sportsWithFavorite = []
        context.gamesBySport = [.nba: 20]
        let shown = date("2026-08-01T12:00:00Z")
        state.markShown(.claimUsername, now: shown)
        XCTAssertNil(MomentEngine.next(context: context, state: state,
                                       now: shown.addingTimeInterval(-100 * 3600)))
    }

    func testMomentRetiresAfterTwoShows() {
        var context = baseline()
        context.hasUsername = false
        context.gamesPlayed = 20
        let start = date("2026-08-01T12:00:00Z")

        state.markShown(.claimUsername, now: start)
        XCTAssertEqual(MomentEngine.next(context: context, state: state,
                                         now: start.addingTimeInterval(72 * 3600)),
                       .claimUsername)

        state.markShown(.claimUsername, now: start.addingTimeInterval(72 * 3600))
        XCTAssertNil(MomentEngine.next(context: context, state: state,
                                       now: start.addingTimeInterval(144 * 3600)))
    }

    func testSatisfiedMomentRetiresImmediately() {
        var context = baseline()
        context.hasUsername = false
        context.gamesPlayed = 20
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .claimUsername)

        state.markSatisfied(.claimUsername)
        XCTAssertTrue(state.isRetired(.claimUsername))
        XCTAssertNil(MomentEngine.next(context: context, state: state))
    }

    /// Retirement is per moment, not global: satisfying one must leave the next one available.
    func testRetiringOneMomentLeavesTheOthersAvailable() {
        var context = baseline()
        context.sportsWithFavorite = []
        context.gamesBySport = [.nba: 20]
        state.markSatisfied(.claimUsername)
        XCTAssertEqual(MomentEngine.next(context: context, state: state), .favoriteTeam(.nba))
    }

    /// The show cap and cooldown are keyed on `analyticsID`, which collapses every sport onto one
    /// `favorite_team` id — so playing five sports can't buy five asks.
    func testFavoriteTeamShowCapIsSharedAcrossSports() {
        XCTAssertEqual(Moment.favoriteTeam(.nba).analyticsID, Moment.favoriteTeam(.soccer).analyticsID)
        state.markShown(.favoriteTeam(.nba))
        state.markShown(.favoriteTeam(.nba))
        XCTAssertTrue(state.isRetired(.favoriteTeam(.soccer)))
    }

    // MARK: - Schema stability

    /// These land in `events.properties->>'moment'` and in persisted UserDefaults keys. A rename
    /// silently splits a funnel in the warehouse *and* re-arms a retired prompt for every
    /// existing install, so it has to break a test instead — same rule `ActivationFunnelTests`
    /// applies to the activation funnel.
    func testMomentIDsAreStable() {
        XCTAssertEqual(Moment.claimUsername.analyticsID, "claim_username")
        XCTAssertEqual(Moment.favoriteTeam(.nfl).analyticsID, "favorite_team")
        XCTAssertEqual(Moment.addFriend.analyticsID, "add_friend")
    }

    func testMomentEventNamesAreStable() {
        XCTAssertEqual(AnalyticsEvent.momentShown.rawValue, "moment_shown")
        XCTAssertEqual(AnalyticsEvent.momentAccepted.rawValue, "moment_accepted")
        XCTAssertEqual(AnalyticsEvent.momentCompleted.rawValue, "moment_completed")
    }

    func testMomentTriggerRawValuesAreStable() {
        XCTAssertEqual(MomentTrigger.foreground.rawValue, "foreground")
        XCTAssertEqual(MomentTrigger.postGame.rawValue, "post_game")
    }

    /// The `moment_shown` bag is what the funnel query groups by; a dropped key is a column of
    /// nulls nobody notices until they try to use it.
    func testShownPropertiesCarryTheFunnelDimensions() {
        var context = baseline()
        context.gamesPlayed = 12
        context.dayIndex = 3
        XCTAssertEqual(context.properties(moment: .claimUsername, trigger: .postGame),
                       ["moment": "claim_username", "trigger": "post_game",
                        "games_played": "12", "day_index": "3"])
        // The sport a team was asked about is the one dimension that only one moment has.
        XCTAssertEqual(context.properties(moment: .favoriteTeam(.soccer), trigger: .foreground)["sport"],
                       "soccer")
    }

    // MARK: - Armed vs shown accounting (M21-2)

    /// `MomentPresenter` arms without billing: `markShown` fires at *appear* time, so an inline
    /// arm (a player foregrounded on a non-Home tab) must leave `showCount` untouched. The arm
    /// is inline exactly because one show already happened.
    @MainActor
    func testArmingInlineDoesNotIncrementShowCount() {
        state.markShown(.claimUsername, now: date("2026-08-01T12:00:00Z"))
        let presenter = MomentPresenter(state: state)
        presenter.present(.claimUsername, trigger: .postGame, context: baseline())

        XCTAssertEqual(presenter.style, .inline)
        XCTAssertEqual(presenter.pending, .claimUsername)
        XCTAssertEqual(state.showCount(.claimUsername), 1)
    }

    /// The surface reporting its appearance is the one event that bills the show — counting in
    /// `MomentState` and the `moment_shown` row both happen there, exactly once.
    @MainActor
    func testAppearingIncrementsShowCountExactlyOnce() {
        state.markShown(.claimUsername, now: date("2026-08-01T12:00:00Z"))
        let presenter = MomentPresenter(state: state)
        let container = RepositoryContainer.make(client: nil)
        presenter.present(.claimUsername, trigger: .postGame, context: baseline())

        presenter.markShown(container: container)
        XCTAssertEqual(state.showCount(.claimUsername), 2)
        XCTAssertTrue(state.isRetired(.claimUsername))
    }

    /// A surface can re-report its appearance (a sheet mounting twice across a transition, a
    /// card remounting on a Home return) — the same duplicate-row failure mode `trackedStep`
    /// and `recordedOpen` guard against. The second report must be a no-op.
    @MainActor
    func testReportingAppearanceTwiceCountsOnce() {
        state.markShown(.claimUsername, now: date("2026-08-01T12:00:00Z"))
        let presenter = MomentPresenter(state: state)
        let container = RepositoryContainer.make(client: nil)
        presenter.present(.claimUsername, trigger: .postGame, context: baseline())

        presenter.markShown(container: container)
        presenter.markShown(container: container)
        XCTAssertEqual(state.showCount(.claimUsername), 2)
    }

    /// An inline moment armed while the player is elsewhere is *armed, not shown*: nothing is
    /// billed, nothing retires, and a later evaluation picks it up again with its count intact.
    @MainActor
    func testNeverShownInlineMomentStaysEligibleLater() {
        state.markShown(.claimUsername, now: date("2026-08-01T12:00:00Z"))
        let presenter = MomentPresenter(state: state)
        presenter.present(.claimUsername, trigger: .foreground, context: baseline())
        presenter.dismiss()   // the player never reached Home

        XCTAssertEqual(state.showCount(.claimUsername), 1)
        XCTAssertFalse(state.isRetired(.claimUsername))

        // A later trigger's evaluation still finds it eligible and arms it again.
        var later = baseline()
        later.hasUsername = false
        later.gamesPlayed = MomentEngine.usernameGameThreshold
        XCTAssertEqual(MomentEngine.next(context: later, state: state), .claimUsername)

        presenter.present(.claimUsername, trigger: .foreground, context: later)
        XCTAssertEqual(presenter.style, .inline)
        XCTAssertEqual(state.showCount(.claimUsername), 1)
    }

    /// The session guard is set at *arm* time, not appear time: a moment armed and never shown
    /// still counts as "asked this session", so a second trigger can't arm something else on
    /// top of it. `evaluate` returns before touching any state here — `shownThisSession` blocks
    /// it at the gate — which keeps this hosted test off `UserDefaults.standard`.
    @MainActor
    func testSessionGuardBlocksSecondArmWhenFirstWasNeverShown() async {
        state.markShown(.claimUsername, now: date("2026-08-01T12:00:00Z"))
        let presenter = MomentPresenter(state: state)
        let container = RepositoryContainer.make(client: nil)
        presenter.present(.claimUsername, trigger: .foreground, context: baseline())
        XCTAssertEqual(state.showCount(.claimUsername), 1)
        presenter.dismiss()

        await presenter.evaluate(container: container, trigger: .foreground)
        XCTAssertNil(presenter.pending)
        XCTAssertEqual(state.showCount(.claimUsername), 1)
    }

    /// The sheet's accounting is unchanged by the split: arming the first ask is still a sheet,
    /// and its appearance report is what bills the show.
    @MainActor
    func testSheetMomentCountsOnAppearance() {
        let presenter = MomentPresenter(state: state)
        let container = RepositoryContainer.make(client: nil)
        presenter.present(.claimUsername, trigger: .foreground, context: baseline())

        XCTAssertEqual(presenter.style, .sheet)
        XCTAssertEqual(state.showCount(.claimUsername), 0)

        presenter.markShown(container: container)
        XCTAssertEqual(state.showCount(.claimUsername), 1)
    }

    /// The debug forced path exists to screenshot a moment, not to bill the player for one —
    /// even a reported appearance must not consume a show.
    @MainActor
    func testForcedMomentNeverBillsAShow() {
        let presenter = MomentPresenter(state: state)
        let container = RepositoryContainer.make(client: nil)
        presenter.present(.claimUsername, trigger: .foreground, context: baseline(), record: false)

        presenter.markShown(container: container)
        XCTAssertEqual(state.showCount(.claimUsername), 0)
    }
}
