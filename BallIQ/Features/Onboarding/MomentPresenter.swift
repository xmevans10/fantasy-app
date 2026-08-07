import SwiftUI

/// How a moment gets put in front of the player.
///
/// The first ask is a sheet — it's the only presentation that reliably gets read, and these are
/// one-time asks with a real payoff behind them. A *second* ask de-escalates to Home's inline
/// prompt slot (the shape `pushPrimerCard` already occupies), because interrupting someone twice
/// for the same thing is where a nudge turns into nagging. There is no third ask
/// (`MomentState.maxShows`).
enum MomentStyle {
    case sheet
    case inline
}

/// Owns "is a moment on screen right now", arms one when a trigger fires, and writes the funnel.
///
/// Separate from `RepositoryContainer` on purpose: this is presentation state with a session
/// lifetime, not repository state, and keeping it out means `RepositoryContainer` doesn't gain a
/// published property that re-renders every screen in the app whenever a prompt opens or closes.
/// Injected from `BallIQApp` alongside the container, same as `AuthService`.
@MainActor
final class MomentPresenter: ObservableObject {
    /// The armed moment, or nil. Read by `ContentView` (sheet) and `HomeView` (inline card);
    /// only ever written here.
    @Published private(set) var pending: Moment?
    @Published private(set) var style: MomentStyle = .sheet
    /// The situation the pending moment was armed for. Published because the copy is built from
    /// it — "you've played 5" is the entire reason these land, and a view that had to re-derive
    /// the count would hit the career-log actor again mid-render.
    @Published private(set) var context = MomentContext()

    /// One moment per app session, whatever else qualifies. The 48h cooldown in `MomentState`
    /// already covers the common case, but a session that spans a cooldown boundary (the app
    /// sitting in memory for days, which iOS does routinely) would otherwise arm a second one
    /// mid-use — the same class of bug `HomeView.dailiesDay` exists to prevent.
    ///
    /// Set at *arm* time, not appear time: it exists to stop a second moment arming while the
    /// first is still live, and an inline moment can sit armed on a tab the player never visits.
    private var shownThisSession = false

    /// False only on the debug forced path (`-screenshotMoment`): that path exists to
    /// screenshot a moment, not to bill the player for one.
    private var shouldRecord = true

    /// Idempotency guard for `markShown`. The surfaces report their own appearance, and a sheet
    /// or card can legitimately report twice (presentation transitions, tab round-trips) — a
    /// second report must not double-count a show. Duplicate rows in the production `events`
    /// table have bitten this repo twice before, which is what the `trackedStep` and
    /// `recordedOpen` guards exist to prevent. Reset whenever a new moment is armed or cleared.
    private var hasRecordedCurrent = false

    /// The trigger the pending moment was armed with. `moment_shown` carries it in the event's
    /// properties, and the show is now recorded by the surface, which no longer has it.
    private var trigger: MomentTrigger = .foreground

    private let state: MomentState

    init(state: MomentState = MomentState()) {
        self.state = state
    }

    // MARK: - Arming

    /// Considers arming a moment. Cheap and safe to call on every trigger — the engine says no
    /// nearly every time, and this returns early before touching the career log when it can.
    ///
    /// **Must never be called from inside a game view.** A `.sheet` cannot present over a live
    /// `fullScreenCover`; it fails silently, and the moment would be burned (marked shown) for a
    /// sheet nobody saw. Call sites are the cover's `onDismiss` and `scenePhase` becoming active.
    func evaluate(container: RepositoryContainer, trigger: MomentTrigger) async {
        let forced = DebugLaunch.forcedMoment
        guard pending == nil else { return }
        guard forced != nil || !shownThisSession else { return }
        // A signed-in player whose profile hasn't landed yet reads as having no username, no
        // favorite team and no friends — i.e. eligible for all three, wrongly. Wait rather than
        // guess; the next trigger (there's always another) will find the data there.
        guard forced != nil || container.isProfileLoaded else { return }
        // Built even on the forced path: the debug flags exist to *screenshot* these, and a
        // moment rendered against a zeroed context would capture "you've played 0" — the exact
        // copy the real one never shows.
        let context = await context(container: container)
        if let forced {
            present(forced, trigger: trigger, context: context, record: false)
            return
        }
        guard let moment = MomentEngine.next(context: context, state: state) else { return }
        present(moment, trigger: trigger, context: context)
    }

    /// Arms the moment. Decided from the count *before* this show is recorded: show #1 is the
    /// sheet, show #2 is the quieter inline card.
    ///
    /// Nothing is counted or logged here — the surface bills its own appearance via
    /// `markShown(container:)`, and only that consumes a show. Until then an armed moment costs
    /// nothing: an inline arm on a tab the player never visits stays eligible on a later trigger.
    /// The one exception is `record: false` (the debug forced path), which must never bill.
    ///
    /// Internal rather than private so the accounting tests can arm deterministically:
    /// `evaluate`'s context assembly reads `UserDefaults.standard`, which hosted tests must not.
    func present(_ moment: Moment, trigger: MomentTrigger, context: MomentContext,
                 record: Bool = true) {
        style = state.showCount(moment) == 0 ? .sheet : .inline
        self.context = context
        self.trigger = trigger
        pending = moment
        shouldRecord = record
        hasRecordedCurrent = false
        guard record else { return }
        shownThisSession = true
    }

    /// Snapshot of the player, assembled from the same sources the rest of the app reads. The
    /// career log is the authority on volume (`ProgressSnapshot` only carries a streak and XP,
    /// and XP is also written by `RemoteSync.pull()` — a returning player signing in on a new
    /// device would otherwise look like they'd played hundreds of games here on day one).
    private func context(container: RepositoryContainer) async -> MomentContext {
        let rows = await container.gameLog.all()
        var bySport: [Sport: Int] = [:]
        for row in rows { bySport[row.sport, default: 0] += 1 }
        let activation = ActivationState()
        return MomentContext(
            hasOnboarded: UserDefaults.standard.bool(forKey: "hasOnboarded"),
            hasCompletedFirstGame: activation.has(.firstGameCompleted),
            isSignedIn: container.isSignedIn,
            dayIndex: activation.currentDayIndex(),
            gamesPlayed: rows.count,
            gamesBySport: bySport,
            streak: container.streak,
            hasUsername: container.identity.username != nil,
            sportsWithFavorite: Set(container.favoriteTeams.teams.keys.compactMap(Sport.init(rawValue:))),
            acceptedFriends: container.acceptedFriends,
            pushPrimerPending: await PushPrimer.shouldOffer(streak: container.streak))
    }

    // MARK: - Outcomes

    /// Promote an inline card to the full sheet — what tapping the card's CTA does. The moment is
    /// already armed and already counted; this only changes how it's drawn, so the second ask
    /// still costs the player exactly one interruption, and only one they asked for.
    func escalate() {
        guard pending != nil else { return }
        style = .sheet
    }

    /// The armed moment's surface actually appeared — the sheet mounted, or Home rendered the
    /// inline card. This is the instant the show is billed: counted in `MomentState` and logged
    /// as `moment_shown`, exactly once per armed moment.
    ///
    /// The surfaces call this on every appearance. Idempotent via `hasRecordedCurrent` because
    /// appearances re-fire — a sheet can mount twice across a transition, and leaving Home and
    /// coming back remounts the card. A second report must not double-count.
    func markShown(container: RepositoryContainer) {
        guard let moment = pending, !hasRecordedCurrent else { return }
        hasRecordedCurrent = true
        guard shouldRecord else { return }
        state.markShown(moment)
        container.track(.momentShown, context.properties(moment: moment, trigger: trigger))
    }

    /// The CTA was tapped. Doesn't close anything — the moment's own destination (the identity
    /// editor, the team picker, Friends) opens on top and the moment closes behind it.
    func accept(_ moment: Moment, container: RepositoryContainer) {
        container.track(.momentAccepted, ["moment": moment.analyticsID])
    }

    /// The player actually did the thing. Retires the moment for good and closes it.
    func complete(_ moment: Moment, container: RepositoryContainer) {
        state.markSatisfied(moment)
        container.track(.momentCompleted, ["moment": moment.analyticsID])
        clear()
    }

    /// Dismissed without acting. No event — dismissals are `moment_shown` minus
    /// `moment_accepted`, and storing a derivable fact twice is how two counts start disagreeing.
    func dismiss() {
        clear()
    }

    private func clear() {
        pending = nil
        hasRecordedCurrent = false
        shouldRecord = true
    }
}
