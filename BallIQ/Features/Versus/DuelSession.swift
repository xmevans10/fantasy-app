import SwiftUI

/// A timed Versus duel in progress, handed to a game view so it can run the clock, show it, and
/// submit when it runs out.
///
/// **The clock is server-authoritative.** `secondsRemaining` is whatever
/// `start_versus_challenge` returned — the server sets `*_started_at` the first time a player
/// opens the board and computes the remainder itself, so nothing here trusts the device clock's
/// absolute value, only its rate. Re-opening a duel after a crash resumes the same countdown
/// rather than restarting it, because the server never rewrites `started_at`.
///
/// One type for all three formats (AGENTS.md §4). The formats differ in what a "decision" is and
/// in nothing else that matters to a countdown.
struct DuelSession: Equatable, Identifiable {
    /// What the duel is addressed by: a `versus_challenges` row id for a human duel, or a
    /// `ladder_rungs.rung` for a bot duel. `ladder` below is the discriminator — when it is
    /// non-nil this is a rung number and no challenge row exists anywhere.
    let challengeID: Int
    /// The `puzzles.id` this duel is played on.
    ///
    /// Carried on the session rather than left to each game view to work out, because two of
    /// the three can't: `GridPuzzle` and `Keep4Puzzle` content does not embed the row id for
    /// Grid, and only the fetch site knows which id it asked for. The career log needs it so a
    /// duel run is attributed to its real board.
    let boardID: String
    /// Set when the opponent is a ladder bot. Nil means a human on the other end.
    ///
    /// The bot's whole run is computed *before* the board opens, so "playing alongside" it is
    /// just revealing beats as the clock passes them — no server round trip, no realtime
    /// transport, and the same thing happens on every device because the run is seeded.
    let ladder: LadderRunSession?
    let format: PuzzleFormat
    /// The other side of the duel, resolved by the caller (the local user may be either the
    /// challenger or the opponent on a row). Denormalized onto
    /// `GameResultDetails.opponentUserID` so a "record against this rival" stat doesn't need a
    /// challenge lookup.
    let opponentUserID: String?
    let opponentName: String?
    /// Server-authoritative seconds left at the instant `capturedAt` was taken.
    let secondsRemaining: Int
    /// Device wall clock when `secondsRemaining` was captured. The countdown is derived from
    /// this rather than from a timer that ticks — a timer stops in the background, and a duel
    /// that pauses when you switch apps is not a duel.
    let capturedAt: Date

    var id: Int { challengeID }

    init(challengeID: Int, format: PuzzleFormat, boardID: String,
         opponentUserID: String?, opponentName: String?,
         secondsRemaining: Int, capturedAt: Date = Date(), ladder: LadderRunSession? = nil) {
        self.challengeID = challengeID
        self.boardID = boardID
        self.ladder = ladder
        self.format = format
        self.opponentUserID = opponentUserID
        self.opponentName = opponentName
        self.secondsRemaining = secondsRemaining
        self.capturedAt = capturedAt
    }

    var deadline: Date { capturedAt.addingTimeInterval(TimeInterval(secondsRemaining)) }

    func secondsLeft(at now: Date = Date()) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    func isExpired(at now: Date = Date()) -> Bool { now >= deadline }

    /// "1:45" / "0:09". Minutes-and-seconds throughout rather than switching to a bare seconds
    /// count under a minute — a clock that changes shape mid-duel is one more thing to parse
    /// at exactly the moment there's no attention to spare.
    static func clockText(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

/// A started duel plus the board it is played on, ready to present.
///
/// One case per duelable format, because the three game views take three genuinely different
/// content types — `PuzzleFormat` is the shared *identity*, but the payloads aren't. Shared by
/// the Versus tab and the ladder rather than written twice: both do exactly the same thing
/// (start a clock, fetch a board by id, present it), and only where the clock comes from
/// differs.
enum DuelBoard: Identifiable {
    case keep4(DuelSession, Keep4Puzzle)
    case grid(DuelSession, GridPuzzle)
    case whoami(DuelSession, WhoAmIPuzzle)

    var session: DuelSession {
        switch self {
        case .keep4(let s, _), .grid(let s, _), .whoami(let s, _): return s
        }
    }

    var id: String { "\(session.ladder == nil ? "v" : "l")\(session.challengeID)" }

    /// The game view for this board. Every duel — human or bot, any format — presents through
    /// here, so a change to how duels are played is one edit rather than six.
    @ViewBuilder var view: some View {
        switch self {
        case .keep4(let session, let puzzle):
            Keep4GameView(puzzle: puzzle, ranked: false, duel: session)
        case .grid(let session, let puzzle):
            GridGameView(duel: session, duelPuzzle: puzzle)
        case .whoami(let session, let puzzle):
            WhoAmIGameView(puzzle: puzzle, ranked: false, duel: session)
        }
    }
}

/// A ladder rung in progress: the bot, its pre-computed run, and where it is on the clock.
///
/// This is the whole of the "live opponent" illusion. `BotSolver` produced `run.beats` — a real
/// decision at a real timestamp — before the board opened, so showing the bot's score climbing
/// alongside the player is a lookup, not a subscription. `Phase 3`'s deferred websocket layer
/// would replace exactly this and nothing else.
struct LadderRunSession: Equatable {
    let rung: LadderRung
    let bot: LadderBot
    let run: BotRun

    /// The bot's score as of `elapsed` seconds into the run.
    func botScore(after elapsed: TimeInterval) -> Int {
        run.beats.reduce(0) { $0 + (($1.at <= elapsed && $1.correct) ? 1 : 0) }
    }

    /// Whether the bot has finished its whole board yet — worth saying out loud, because
    /// "3/9" means something very different before and after the bot is done.
    func isDone(after elapsed: TimeInterval) -> Bool { elapsed >= run.elapsed }

    var outOf: Int { run.outOf }

    /// The bot's run in the unit the result banner compares — which is not always
    /// `run.correct`/`run.outOf`.
    ///
    /// Keep4 and Grid have a natural "N of M correct" and use it directly. Who Am I? does not:
    /// one guess is either right or wrong, so `BotRun` reports 1/1, while the player's side is
    /// measured in **clue efficiency** out of 6 (`ChallengeLink.whoAmIHits`). Comparing 1/1
    /// against 5/6 would be nonsense, so the bot is converted onto the player's scale here —
    /// its `beats` are one per revealed clue, so their count *is* the clues it used.
    var verdictHits: (hits: Int, outOf: Int) {
        switch rung.mode {
        case .keep4, .grid:
            return (run.correct, run.outOf)
        case .whoami:
            let solved = run.correct > 0
            let cluesUsed = max(1, run.beats.count)
            return (solved ? max(0, ChallengeLink.whoAmIOutOf + 1 - cluesUsed) : 0,
                    ChallengeLink.whoAmIOutOf)
        }
    }

    /// The finished head-to-head, ready for `ChallengeResultBanner`. A tie goes to the player:
    /// a bot is not a person whose feelings the tiebreak has to be fair to, and matching the
    /// machine is a win worth having. Matches `LadderOutcome.playerWon`, which decides what is
    /// actually recorded.
    func verdict(myHits: Int) -> DuelVerdict {
        let theirs = verdictHits
        // A tie goes to the player, so the bot "won" only by outscoring outright — the closing
        // line has to agree with the banner's own verdict or the character reads as broken.
        let botWon = theirs.hits > myHits
        return DuelVerdict(opponentName: bot.name, myHits: myHits, theirHits: theirs.hits,
                           outOf: theirs.outOf, myScore: nil, theirScore: nil,
                           closingLine: bot.voice.closing(botWon: botWon,
                                                          playerPerfect: myHits == theirs.outOf),
                           tieGoesToPlayer: true)
    }
}

/// Decides when a ladder bot's live score change is worth a speech-bubble reaction, and enforces
/// the budget — pulled out of `DuelTimerBar` so the crossing/cap/gap policy is unit-testable
/// without a hosted view (see `DuelReactionTests`).
///
/// "Crossing" is tracked through a tie rather than reset by one: if the bot pulls ahead, dips
/// back level, then pulls ahead again, that is still the *same* lead, not a second reaction. Only
/// `lastNonzeroSign` flipping counts.
struct DuelReactionEngine: Equatable {
    private var lastNonzeroSign = 0
    private(set) var firedCount = 0
    private var lastFiredAt: Date?

    /// "How much character expression before it's distracting" — the brief's own answer, on a
    /// 60-second timed board, is: very little.
    static let maxReactions = 2
    static let minGap: TimeInterval = 8

    /// Call on every score tick with the bot's authored lines for each direction. Returns the
    /// line to show, or nil if nothing should fire this tick — either because the score hasn't
    /// crossed, the bot has no authored line for that direction (silence beats a filler line,
    /// and costs nothing against the budget), the budget is spent, or the last reaction was too
    /// recent.
    mutating func reactionLine(diff: Int, ahead: String?, behind: String?, now: Date) -> String? {
        let sign = diff == 0 ? 0 : (diff > 0 ? 1 : -1)
        guard sign != 0, sign != lastNonzeroSign else { return nil }
        lastNonzeroSign = sign
        guard let line = sign > 0 ? ahead : behind, !line.isEmpty else { return nil }
        guard firedCount < Self.maxReactions else { return nil }
        if let lastFiredAt, now.timeIntervalSince(lastFiredAt) < Self.minGap { return nil }
        firedCount += 1
        lastFiredAt = now
        return line
    }
}

/// The duel clock, pinned to the top of whichever board is being played.
///
/// Drives itself off a `TimelineView(.periodic)` rather than a `Timer` + `@State`: a `Timer`
/// invalidates when the app backgrounds and would silently hand back time, and `TimelineView`
/// recomputes from the real date on every redraw, so the displayed number is always
/// `deadline - now` no matter what happened in between.
struct DuelTimerBar: View {
    let session: DuelSession
    /// The player's own live tally, in whatever unit this format's game view already tracks —
    /// `Keep4GameView.placement.count`, `GridGameView.solved.count`,
    /// `WhoAmIGameView.revealedCount`. Only meaningful (and only read) when `session.ladder` is
    /// set: a human duel has no live opposing number to compare against, so this is nil there.
    ///
    /// Not a true apples-to-apples score in every format — Keep4 is a blind sort, so
    /// `placement.count` is cards *decided*, not cards known-correct, unlike Grid's `solved`
    /// (which only holds confirmed-correct guesses). One shared optional beats three bespoke
    /// comparison paths (AGENTS.md §4); the reaction is a vibe ("who's pulling ahead right now"),
    /// not a claim about final accuracy, and the result screen's real verdict is unaffected by it.
    var playerScore: Int? = nil
    /// Fired once, when the clock reaches zero. The game view is expected to finish the run
    /// with whatever the player has so far — an expired duel still has to resolve.
    let onExpire: () -> Void

    @State private var didExpire = false
    @State private var reactionEngine = DuelReactionEngine()
    @State private var reactionText: String?
    @State private var reactionToken: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Under this many seconds the bar goes red and starts pulsing.
    private let urgentThreshold = 10
    /// How long a reaction bubble stays up before it auto-dismisses.
    private let reactionDuration: TimeInterval = 2.5

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let left = session.secondsLeft(at: context.date)
                let urgent = left <= urgentThreshold
                let elapsed = TimeInterval(session.secondsRemaining - left)
                let botScore = session.ladder?.botScore(after: elapsed)
                HStack(spacing: 10) {
                    if let ladder = session.ladder, let botScore {
                        // The bot's score, climbing in real time off its pre-computed beats. This
                        // is the entire "live opponent" mechanic — see `LadderRunSession`.
                        Text(ladder.bot.avatar).font(.system(size: 15))
                        Text(ladder.bot.name).font(.label11).lineLimit(1)
                        Text("\(botScore)/\(ladder.outOf)")
                            .font(.custom(FontName.condBlack, size: 15))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .opacity(ladder.isDone(after: elapsed) ? 1 : 0.85)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(session.opponentName.map { String(localized: "DUEL vs \($0)") }
                             ?? String(localized: "DUEL"))
                            .font(.label11)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(DuelSession.clockText(left))
                        .font(.custom(FontName.condBlack, size: 20))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(urgent ? Color.onDanger : Color.onAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(urgent ? Color.dangerFill : Color.accentFill)
                .opacity(urgent && left % 2 == 1 ? 0.82 : 1)
                .animation(Motion.snap, value: urgent)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(session.ladder.map { ladder in
                    Text("\(ladder.bot.name) is on \(ladder.botScore(after: TimeInterval(session.secondsRemaining - left))) of \(ladder.outOf). \(left) seconds left")
                } ?? Text("Duel clock, \(left) seconds left"))
                .onChange(of: left) { _, newValue in
                    // `onChange` rather than a check in `body`: mutating state during a view
                    // update is what SwiftUI warns about, and the callback almost always
                    // dismisses or rebuilds this view.
                    guard newValue <= 0, !didExpire else { return }
                    didExpire = true
                    Haptics.reject()
                    onExpire()
                }
                .onChange(of: botScore.map { $0 - (playerScore ?? 0) }) { _, diff in
                    guard let diff, let bot = session.ladder?.bot else { return }
                    if let line = reactionEngine.reactionLine(diff: diff, ahead: bot.voice.ahead,
                                                              behind: bot.voice.behind, now: Date()) {
                        showReaction(line)
                    }
                }
            }
            reactionBubble
        }
    }

    /// Fades or slides+fades in, sits for `reactionDuration`, then fades back out — never blocks
    /// a tap (it's inline content, not an overlay, so it never sits on top of the board or the
    /// current card) and never steals VoiceOver focus (an `.accessibilityAnnouncement` speaks it
    /// without moving focus to it).
    @ViewBuilder
    private var reactionBubble: some View {
        if let reactionText, let bot = session.ladder?.bot {
            HStack(alignment: .top, spacing: 8) {
                Text(bot.avatar).font(.system(size: 13))
                Text(reactionText)
                    .font(.label12)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface1)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            }
            .transition(reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                      removal: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(bot.name): \(reactionText)")
        }
    }

    private func showReaction(_ text: String) {
        let token = UUID()
        reactionToken = token
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.easeOut) {
            reactionText = text
        }
        // Announced rather than focus-shifted: a duel has a clock running, and moving VoiceOver
        // focus to a bubble that auto-dismisses in 2.5s would strand the player mid-navigation.
        AccessibilityNotification.Announcement(text).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + reactionDuration) {
            guard reactionToken == token else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.easeOut) {
                reactionText = nil
            }
        }
    }
}

/// "REMATCH" beside "DONE" on every ladder result screen — one shared button rather than three
/// copies (AGENTS.md §4), since all three result views need the identical loading/disabled
/// dance around `EnvironmentValues.ladderRematch`.
///
/// Stays on `accentFill` (via `ctaLabel()`'s default) whether the run was won or lost —
/// `dangerFill` would dress a rematch as a punishment, when the whole point is that losing to a
/// bot is an invitation, not a verdict.
struct RematchButton: View {
    @Binding var rematching: Bool
    let action: () async -> Bool

    var body: some View {
        Button {
            guard !rematching else { return }
            rematching = true
            Task {
                let started = await action()
                // On success the game view this button lives in is about to be torn down for a
                // fresh one (`LadderView` re-identifies the presented content by the new board's
                // id), so there's nothing left here to reset. On failure, give the button back.
                if !started { rematching = false }
            }
        } label: {
            Text(rematching ? "STARTING…" : "REMATCH")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .ctaLabel()
        }
        .buttonStyle(PrimePressStyle())
        .disabled(rematching)
    }
}

#Preview {
    let bot = LadderBot(id: "analyst", name: "The Analyst", avatar: "\u{1F399}\u{FE0F}",
                        tagline: "Has an opinion, and a graph to back it.",
                        baseSkill: 0.7, persona: "")
    let rung = LadderRung(rung: 17, tier: .silver, mode: .grid, sport: .nba,
                          puzzleId: "grid-nba-2026-08-02", botId: "analyst", botSkill: 0.7,
                          timeLimitSeconds: 107, seed: 1, isBoss: false)
    let run = BotRun(performance: 6.0 / 9, correct: 6, outOf: 9,
                     beats: (0..<9).map { BotBeat(at: Double($0) * 8 + 4, index: $0, correct: $0 < 6) })
    VStack(spacing: 0) {
        // Human duel, comfortable.
        DuelTimerBar(session: DuelSession(challengeID: 1, format: .keep4, boardID: "p",
                                          opponentUserID: nil, opponentName: "hoopsfan",
                                          secondsRemaining: 95)) {}
        // Human duel, no username to show, urgent (red + pulse).
        DuelTimerBar(session: DuelSession(challengeID: 2, format: .grid, boardID: "p",
                                          opponentUserID: nil, opponentName: nil,
                                          secondsRemaining: 7)) {}
        // Ladder duel — the widest state: emoji + a long bot name + a live score + the clock.
        DuelTimerBar(session: DuelSession(challengeID: 17, format: .grid,
                                          boardID: "grid-nba-2026-08-02", opponentUserID: nil,
                                          opponentName: nil, secondsRemaining: 107,
                                          ladder: LadderRunSession(rung: rung, bot: bot, run: run))) {}
        Spacer()
    }
    .background(Color.appBackground)
}
