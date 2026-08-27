import Foundation

/// The first-run screens, in the order a new player sees them. Raw values land in
/// `events.properties->>'step'` and the activation funnel query in docs/ANALYTICS.md groups by
/// them, so treat them as a stable schema — the same rule `AnalyticsEvent`'s raw values follow.
/// Locked by `ActivationFunnelTests`: renaming one has to break a test rather than silently
/// split a funnel in the warehouse.
enum OnboardingStep: String, CaseIterable {
    /// One tap — which sport do you know best. The only question a brand-new player can answer
    /// without having played anything, and it pays off immediately (Home's daily pager opens on
    /// that sport).
    case sport     = "sport"
    /// What K4C4 actually is. Doubles as the load state for today's puzzle, which has to happen
    /// somewhere regardless.
    case howToPlay = "how_to_play"
    /// The account ask, deliberately *after* the first game — see `OnboardingView`'s note.
    case account   = "account"
}

/// Install-scoped first-run bookkeeping: when this install first opened, and which activation
/// milestones it has already passed.
///
/// Pulled out of the views for the same reason as `HomeDailyLoop` — the day arithmetic and the
/// fire-exactly-once rules are the part worth unit-testing without SwiftUI. Every entry point
/// takes an injectable `UserDefaults` because BallIQ's unit tests are *hosted* (they run inside
/// the real app process), so a test writing these keys through `.standard` would land in the
/// real app container and corrupt the next launch's funnel — the same trap `DiskCache
/// .directoryOverride` exists for.
struct ActivationState {
    /// One-shot activation milestones. Raw values are the UserDefaults keys; namespaced so they
    /// can't collide with the v0-era progress keys (`streakCount`, `xp`, …) this app still reads.
    enum Milestone: String, CaseIterable {
        case firstGameStarted   = "activation.firstGameStarted"
        case firstGameCompleted = "activation.firstGameCompleted"
        case pushPrimerAnswered = "activation.pushPrimerAnswered"
    }

    /// What a launch tells the funnel. `dayIndex` is the whole retention signal: `1` is the
    /// next-day return the brief asks about, and everything above it is the retention curve.
    struct AppOpen: Equatable {
        let firstOpen: Bool
        let dayIndex: Int

        var properties: [String: String] {
            ["first_open": "\(firstOpen)", "day_index": "\(dayIndex)"]
        }
    }

    private enum Key {
        static let firstOpen = "activation.firstOpenAt"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar

    /// `calendar` is deliberately the *local* one, not UTC: `progress.lastPlayedDay` is a local
    /// day string and the streak-risk push fires at the device's local 8pm, so a "returned the
    /// next day" event measured on UTC days would disagree with the streak it's meant to explain.
    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// Stamps the install's birthday on the very first call and reports how far into its life
    /// this launch is. Safe to call on every launch; only the first one writes.
    func recordOpen(now: Date = Date()) -> AppOpen {
        guard let first = defaults.object(forKey: Key.firstOpen) as? Date else {
            defaults.set(now, forKey: Key.firstOpen)
            return AppOpen(firstOpen: true, dayIndex: 0)
        }
        return AppOpen(firstOpen: false, dayIndex: dayIndex(from: first, to: now))
    }

    /// How far into this install's life we are, **without** stamping anything. `recordOpen` is
    /// the launch-time writer and must stay the only one; a reader that went through it would
    /// silently claim the install's birthday for whatever moment happened to ask first on a
    /// fresh install, making every later `day_index` wrong. Returns 0 before the first
    /// `recordOpen`, which is also the honest answer (today is day 0).
    func currentDayIndex(now: Date = Date()) -> Int {
        guard let first = defaults.object(forKey: Key.firstOpen) as? Date else { return 0 }
        return dayIndex(from: first, to: now)
    }

    /// Whole local days between the install's first open and `now`, floored at 0 — a user who
    /// rolls their device clock backwards should read as day 0, not day -3, which would land in
    /// the warehouse as a bucket nobody has a query for.
    func dayIndex(from first: Date, to now: Date) -> Int {
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: first),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return max(0, days)
    }

    func has(_ milestone: Milestone) -> Bool { defaults.bool(forKey: milestone.rawValue) }

    /// Whether Home should still offer the streak-reminder primer. The OS prompt can only be
    /// shown once per install, so the card must not reappear after the player has answered it
    /// either way (`pushPrimerAnswered`) — a second ask would be a no-op button.
    var shouldOfferPushPrimer: Bool { !has(.pushPrimerAnswered) }

    /// Marks `milestone` and reports whether *this* call was the first one. Callers log the
    /// event only on `true`, which is what keeps `first_game_completed` meaning "first" — a
    /// player who finishes ten puzzles must contribute exactly one row.
    @discardableResult
    func markOnce(_ milestone: Milestone) -> Bool {
        guard !has(milestone) else { return false }
        defaults.set(true, forKey: milestone.rawValue)
        return true
    }
}

/// Whether the streak-reminder card is live right now.
///
/// Two callers need this answer and they must not disagree: `HomeView` renders the card, and
/// `MomentPresenter` suppresses every post-onboarding moment while it's up (one ask at a time —
/// see `MomentContext.pushPrimerPending`). A second copy of the condition would let them drift
/// into a state where Home shows the card *and* a moment sheet opens over it, which is the one
/// outcome both rules exist to prevent. AGENTS.md §4.
///
/// The `DebugLaunch.forcePushPrimer` override deliberately stays at the view: it's a screenshot
/// hook for the card, not a claim that the player is really owed one.
@MainActor
enum PushPrimer {
    /// Gated on the **first completed game**, not on a streak.
    ///
    /// It used to require `streak > 0`. That is the same threshold by a longer route — a streak
    /// only exists once a game is finished — but it read as a retention gate and hid how narrow
    /// it was. Measured against production on 2026-08-26: 64 installs ever started a first game
    /// and 11 finished one, while 120 of 125 first opens ended with push still `notDetermined`.
    /// The primer was positioned downstream of a threshold almost nobody crossed, so the whole
    /// return loop was unreachable for the players who most needed it.
    ///
    /// Asking at the first completed game puts the request where the emotion already is, and
    /// states the trigger the funnel actually measures (`activation.firstGameCompleted`) instead
    /// of a value derived from it.
    static func shouldOffer(state: ActivationState = ActivationState()) async -> Bool {
        guard state.shouldOfferPushPrimer, state.has(.firstGameCompleted) else { return false }
        return await PushNotificationManager.currentAuthorizationStatus() == .notDetermined
    }
}

/// The two "first ever" milestones the daily-puzzle surfaces share. Onboarding's guided first
/// game and Home's daily cards are the only two places a brand-new player's first game can
/// start, and both must agree on what "first" means — so the gate lives here once instead of
/// being re-derived at each call site.
///
/// Deliberately keyed off `hasCompletedToday(puzzleID:)` rather than a jump in XP: XP is also
/// written by `RemoteSync.pull()`, so a returning player signing in on a new device would look
/// like a fresh activation. Local per-puzzle completion can only come from actually playing.
@MainActor
enum ActivationMilestone {
    static func noteFirstGameStarted(_ container: RepositoryContainer, format: String,
                                     sport: Sport, surface: String) {
        guard ActivationState().markOnce(.firstGameStarted) else { return }
        container.track(.firstGameStarted, ["format": format, "sport": sport.rawValue,
                                            "surface": surface])
    }

    static func noteFirstGameCompleted(_ container: RepositoryContainer, format: String,
                                       sport: Sport, surface: String) {
        guard ActivationState().markOnce(.firstGameCompleted) else { return }
        container.track(.firstGameCompleted, ["format": format, "sport": sport.rawValue,
                                              "surface": surface,
                                              "signed_in": "\(container.isSignedIn)"])
    }
}
