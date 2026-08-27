import SwiftUI

/// A blitz run in progress, handed to each board the way `DuelSession` is handed to a duel board.
///
/// The two are deliberately the same shape, because they are the same seam: an externally-owned
/// object that a game view checks to learn "this run isn't mine to finish". A view holding a
/// non-nil `blitz` must not show its own result screen, must not call
/// `RepositoryContainer.complete` (the run banks XP once, at the end, not once per board), and
/// must report its outcome here instead — see `finishRound`.
///
/// **A reference type, unlike `DuelSession`, and for one reason:** the boards report *into* it
/// while the host reads back out of it, so both sides need the same instance. Everything the
/// boards are allowed to see is exposed; the running score deliberately is not (see
/// `BlitzRunSummary` — the score exists only after the clock stops).
@MainActor
final class BlitzSession: ObservableObject {
    let config: BlitzConfig
    let startedAt: Date

    /// Boards finished so far, in order. `@Published` so the host can advance off it and the
    /// status bar can count it; nothing here exposes what any of them were worth.
    @Published private(set) var rounds: [BlitzRoundResult] = []
    /// Set once the run has ended — the clock expired, the board pool ran dry, or the player
    /// left. The host watches this to show the result screen.
    @Published private(set) var isOver = false

    /// The board the clock caught mid-solve, if any. Nil when the run ended on a finished board,
    /// an empty pool, or a deliberate exit.
    @Published private(set) var cutOff: BlitzCutOff?

    /// What is on screen right now, so `expire()` can name it. Not published: nothing renders it
    /// during the run, and publishing it would re-render every board on every advance.
    private var inFlight: BlitzCutOff?

    /// When a board was handed to the player, for that board's own elapsed time. Owned here
    /// rather than read off the game view's `startedAt` so a format that doesn't keep one (or
    /// keeps it for a different purpose) still contributes an honest pace number.
    private var roundStartedAt: Date

    init(config: BlitzConfig, now: Date = Date()) {
        self.config = config
        self.startedAt = now
        self.roundStartedAt = now
    }

    var deadline: Date { startedAt.addingTimeInterval(runSeconds) }

    /// The run's length. Normally the chosen duration; `-blitzSeconds` shortens it for
    /// verification only (compiled out of release — see `DebugLaunch`).
    private var runSeconds: TimeInterval {
        if let override = DebugLaunch.blitzSeconds { return TimeInterval(override) }
        return config.duration.seconds
    }

    func secondsLeft(at now: Date = Date()) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// Whether there is still time to serve another board.
    ///
    /// **The clock now stops the run outright — see `expire(at:)`.** This previously gated only
    /// whether the *next* board was served, deliberately never reaching into the board already on
    /// screen: running out of time meant you played fewer puzzles, never that a puzzle you were
    /// solving got taken away. That reconciliation with M25's "timers are gone" rule was reversed
    /// on request (2026-08-27) — the clock ending is now the run ending, with no grace to finish
    /// the board in flight.
    ///
    /// M25 is not contradicted by this: it removed per-puzzle timers from the *formats*, and
    /// Blitz is the one mode whose entire premise is a clock. What changed is that the clock is
    /// now a hard stop rather than a soft one.
    func acceptsNewRound(at now: Date = Date()) -> Bool { now < deadline }

    /// Marks the moment the current board became playable, and records what it is so the clock
    /// can name it if it cuts it off. Called by the host as it presents each board, so
    /// `BlitzRoundResult.elapsed` measures time on the board rather than time since the run began.
    func beginRound(format: BlitzFormat, sport: Sport, at now: Date = Date()) {
        roundStartedAt = now
        inFlight = BlitzCutOff(format: format, sport: sport)
    }

    /// The clock reached zero. Ends the run immediately, whatever is on screen.
    ///
    /// The board in flight is recorded as `cutOff` rather than as a round: it has no
    /// `performance`, and inventing one would either pay negative points on a format with a
    /// chance floor or silently drop the player's last board from a screen that exists to
    /// account for every board. It is shown, unscored.
    ///
    /// Idempotent — the deadline task, a foreground re-check and a board finishing on the very
    /// same tick can all race here, and only the first may take effect.
    func expire(at now: Date = Date()) {
        guard !isOver else { return }
        cutOff = inFlight
        isOver = true
    }

    /// Records a finished board and decides whether the run continues.
    ///
    /// `performance` is the format's own rating-engine input, passed through untouched —
    /// `BlitzScoring` does the rebasing, here we only write down what happened. `cleared` is the
    /// format's own notion of "got it" (solved, or beat the chance floor), used for the combo and
    /// the end-of-run tally.
    func finishRound(format: BlitzFormat, sport: Sport, puzzleID: String,
                     performance: Double, cleared: Bool, now: Date = Date()) {
        rounds.append(BlitzRoundResult(format: format, sport: sport, puzzleID: puzzleID,
                                       performance: performance, cleared: cleared,
                                       elapsed: max(0, now.timeIntervalSince(roundStartedAt))))
        // A board finished exactly as the clock ran out counts — it was completed, so there is
        // nothing to cut off. `inFlight` is cleared so a later `expire()` can't name a board the
        // player actually finished.
        inFlight = nil
        if !acceptsNewRound(at: now) { isOver = true }
    }

    /// Ends the run early — the player tapped out of a board. Whatever they'd banked still counts;
    /// quitting a blitz is stopping, not forfeiting.
    func endEarly() {
        guard !isOver else { return }
        isOver = true
    }

    /// The finished run. Only meaningful once `isOver`; the host calls it exactly once.
    func summary(at now: Date = Date()) -> BlitzRunSummary {
        BlitzRunSummary(config: config, rounds: rounds,
                        elapsed: min(runSeconds, max(0, now.timeIntervalSince(startedAt))),
                        cutOff: cutOff)
    }
}

/// The strip pinned above every blitz board: the clock, the board count, and **nothing else**.
///
/// The absence is the feature. "Scoring should be displayed ONLY at the end" is the mode's
/// defining rule, so this deliberately cannot render a total — `BlitzSession` doesn't expose one
/// to render (the arithmetic lives in `BlitzRunSummary`, built after the fact). If a running
/// score ever appears here, something has been added to the session that shouldn't exist.
///
/// A `TimelineView(.periodic)` rather than a `Timer` + `@State`, for the same reason
/// `DuelStatusBar` is: a `Timer` invalidates when the app backgrounds and would silently hand
/// time back, so a run could be paused by switching apps.
struct BlitzStatusBar: View {
    @ObservedObject var session: BlitzSession

    /// Below this the clock turns red and the digits get bigger — the only urgency cue in a mode
    /// that otherwise refuses to nag.
    private let urgentSeconds = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let left = session.secondsLeft(at: context.date)
            let urgent = left <= urgentSeconds
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("BLITZ").font(.label11)
                Spacer(minLength: 8)
                Text(String(localized: "\(session.rounds.count) done"))
                    .font(.label11)
                    .monospacedDigit()
                Text(DuelSession.clockText(left))
                    .font(.custom(FontName.condBlack, size: urgent ? 22 : 20))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(urgent ? Color.onDanger : Color.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(urgent ? Color.dangerFill : Color.accentFill)
            .animation(Motion.snap, value: urgent)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(String(localized:
                "Blitz: \(left) seconds left, \(session.rounds.count) puzzles done")))
        }
    }
}
