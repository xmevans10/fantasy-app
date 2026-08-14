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

/// The duel clock, pinned to the top of whichever board is being played.
///
/// Drives itself off a `TimelineView(.periodic)` rather than a `Timer` + `@State`: a `Timer`
/// invalidates when the app backgrounds and would silently hand back time, and `TimelineView`
/// recomputes from the real date on every redraw, so the displayed number is always
/// `deadline - now` no matter what happened in between.
struct DuelTimerBar: View {
    let session: DuelSession
    /// Fired once, when the clock reaches zero. The game view is expected to finish the run
    /// with whatever the player has so far — an expired duel still has to resolve.
    let onExpire: () -> Void

    @State private var didExpire = false

    /// Under this many seconds the bar goes red and starts pulsing.
    private let urgentThreshold = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let left = session.secondsLeft(at: context.date)
            let urgent = left <= urgentThreshold
            HStack(spacing: 10) {
                if let ladder = session.ladder {
                    // The bot's score, climbing in real time off its pre-computed beats. This
                    // is the entire "live opponent" mechanic — see `LadderRunSession`.
                    let elapsed = TimeInterval(session.secondsRemaining - left)
                    Text(ladder.bot.avatar).font(.system(size: 15))
                    Text(ladder.bot.name).font(.label11).lineLimit(1)
                    Text("\(ladder.botScore(after: elapsed))/\(ladder.outOf)")
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
                // `onChange` rather than a check in `body`: mutating state during a view update
                // is what SwiftUI warns about, and the callback almost always dismisses or
                // rebuilds this view.
                guard newValue <= 0, !didExpire else { return }
                didExpire = true
                Haptics.reject()
                onExpire()
            }
        }
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
