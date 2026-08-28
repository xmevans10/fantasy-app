import SwiftUI

/// How a **live** Journeyman race ended (M23 §1) — kept apart from `DuelVerdict.Outcome`'s
/// plain win/loss/tie because two different mechanisms can each produce what is technically a
/// "win" or a "loss", and the result screen has to say which: naming the player while the
/// opponent was still in it reads nothing like naming them after the opponent had already
/// burned all five guesses, and losing because the opponent solved first reads nothing like a
/// dead-heat draw. Rendering "SOLVED" over a defeat the opponent actually won by being faster —
/// or "OUT OF GUESSES" over a run that was cut short by their solve rather than by the guess
/// limit — is the exact lie this milestone exists to prevent.
enum LiveRaceOutcome: Equatable {
    /// I named the player while the opponent was still active (not yet finished).
    case wonBySolvingFirst
    /// I named the player, but only after the opponent had already exhausted their five guesses
    /// (or given up) — a real win, just not a race that was still live at the finish.
    case wonAfterOpponentExhausted
    /// The opponent named the player first. Ends my board immediately, whatever guess I still
    /// had left — see `JourneymanGameView`'s live poll handler.
    case lostToOpponentSolve
    /// The clock reached zero (or both sides exhausted) with nobody having named the player.
    case draw

    /// Decides the outcome from each side's server-reported terminal flags — never from a
    /// local guess of "I typed the right name", which is why `JourneymanGameView` only calls
    /// this from the poll handler, not from the moment a guess matches.
    ///
    /// `theirSolved` always wins the tiebreak over `mySolved`. `submit_versus_live_result` is
    /// first-write-wins server-side (M23 §3): if both flags somehow read true in the same
    /// snapshot — a stale poll racing a fresh submit — the opponent's solve is the one that
    /// actually closed the challenge and mine never landed. Treating that as a loss is the safe
    /// read: a wrongly-shown loss is embarrassing, a wrongly-shown win on a board the server
    /// recorded as lost is a lie a player could screenshot.
    static func decide(mySolved: Bool, myFinished: Bool,
                       theirSolved: Bool, theirFinished: Bool) -> LiveRaceOutcome {
        if theirSolved { return .lostToOpponentSolve }
        if mySolved { return theirFinished ? .wonAfterOpponentExhausted : .wonBySolvingFirst }
        return .draw
    }
}

struct JourneymanResultView: View {
    let puzzle: JourneymanPuzzle
    let result: JourneymanScoring.Result
    var rewards: RepositoryContainer.SessionRewards? = nil
    /// Whether this was today's daily board, and therefore something a friend can be dared onto
    /// — same distinction `WhoAmIResultView.isDaily` documents. Defaults to the safe answer.
    var isDaily: Bool = false
    var challenge: ChallengeLink? = nil
    var duelVerdict: DuelVerdict? = nil
    /// Set only for a **live** duel (M23) — which of the four race outcomes ended it. The
    /// win/loss/tie badge itself still comes from `duelVerdict` and `ChallengeResultBanner`
    /// (one shared banner, not two — AGENTS.md §4); this only changes the headline above it,
    /// which is the one place a plain win/loss reading would say something untrue about *why*.
    var liveOutcome: LiveRaceOutcome? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.ladderRematch) private var ladderRematch
    @State private var confetti = 0
    @State private var rematching = false

    /// Named on the first guess — the rare one, and the only result that earns the volt hero.
    private var firstGuess: Bool { result.solved && result.guessesUsed == 1 }
    private var heroFill: Color { result.solved ? (firstGuess ? .voltFill : .accentFill) : .surface1 }
    private var heroInk: Color { result.solved ? (firstGuess ? .onVolt : .onAccent) : .textPrimary }

    /// The scoreHeader headline for this run. `result.solved` alone still decides the fill/ink
    /// above (a live win is volt/accent, a live loss or draw is the neutral surface, exactly
    /// like solo) — only the *words* change for a race, because "SOLVED" and "OUT OF GUESSES"
    /// both claim something a live loss-by-being-beaten or a draw didn't actually do.
    /// `String(localized:)` throughout — unlike the string-literal-into-`Text(_:)` spelling this
    /// replaces, a `String` returned from a computed property no longer picks up `Text`'s
    /// `LocalizedStringKey` overload for free, so it has to ask for localization explicitly.
    private var headline: String {
        guard let liveOutcome else {
            return result.solved
                ? (firstGuess ? String(localized: "FIRST-GUESS GENIUS") : String(localized: "SOLVED"))
                : String(localized: "OUT OF GUESSES")
        }
        switch liveOutcome {
        case .wonBySolvingFirst:
            return firstGuess ? String(localized: "FIRST-GUESS GENIUS") : String(localized: "SOLVED FIRST")
        case .wonAfterOpponentExhausted: return String(localized: "SOLVED")
        case .lostToOpponentSolve: return String(localized: "THEY SOLVED IT FIRST")
        case .draw: return String(localized: "DEAD HEAT")
        }
    }

    private var headlineDetail: String {
        guard let liveOutcome else {
            return result.solved
                ? String(localized: "NAMED ON GUESS \(result.guessesUsed) OF \(JourneymanScoring.maxGuesses)")
                : String(localized: "BETTER LUCK TOMORROW")
        }
        switch liveOutcome {
        case .wonBySolvingFirst, .wonAfterOpponentExhausted:
            return String(localized: "NAMED ON GUESS \(result.guessesUsed) OF \(JourneymanScoring.maxGuesses)")
        case .lostToOpponentSolve: return String(localized: "BEATEN TO THE ANSWER")
        case .draw: return String(localized: "CLOCK RAN OUT ON BOTH OF YOU")
        }
    }

    /// Builds the head-to-head banner for a **live** race in the same `DuelVerdict` shape a
    /// bot duel uses (`LadderRunSession.verdict`), so `ChallengeResultBanner` needs no
    /// live-specific case of its own.
    ///
    /// Hits alone fully determine the win/loss/tie here — unlike a bot duel's clue-efficiency
    /// comparison, a live race can never produce two nonzero hit counts (only one side's solve
    /// can land per §3), so `myScore`/`theirScore` never actually break a tie; they're carried
    /// anyway so a future format that *can* tie on hits doesn't have to touch this call site.
    /// `tieGoesToPlayer: false`: unlike the ladder, a dead heat between two humans is a real
    /// tie, not a courtesy win.
    static func liveDuelVerdict(opponentName: String?, myResult: JourneymanScoring.Result,
                                theirGuesses: Int, theirSolved: Bool) -> DuelVerdict {
        let theirHits = theirSolved ? JourneymanScoring.maxGuesses + 1 - theirGuesses : 0
        return DuelVerdict(opponentName: opponentName,
                           myHits: ChallengeLink.journeymanHits(myResult), theirHits: theirHits,
                           outOf: ChallengeLink.journeymanOutOf, myScore: myResult.total,
                           theirScore: nil, tieGoesToPlayer: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    if let duelVerdict, challenge == nil {
                        ChallengeResultBanner(verdict: duelVerdict).heroReveal(1)
                    }
                    if let challenge {
                        ChallengeResultBanner(challenge: challenge,
                                              hits: ChallengeLink.journeymanHits(result),
                                              score: result.total)
                            .heroReveal(1)
                    }
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(challenge == nil ? 1 : 2) }
                    answerCard.heroReveal(challenge == nil ? 2 : 3)
                    fullPath.heroReveal(challenge == nil ? 3 : 4)
                    shareRow.heroReveal(challenge == nil ? 4 : 5)
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: firstGuess ? 90 : 50)
        .onAppear {
            if let challenge {
                container.track(.challengeCompleted, [
                    "format": PuzzleFormat.journeyman.rawValue,
                    "sport": puzzle.sport.rawValue,
                    "outcome": String(describing: challenge.outcome(
                        hits: ChallengeLink.journeymanHits(result), score: result.total)),
                ])
            }
            if result.solved { confetti += 1 }
        }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(headline)
                .font(.heading)
                .foregroundStyle(heroInk.opacity(0.85))

            CountUpText(value: result.total, font: .heroNumber, color: heroInk)

            Text(headlineDetail)
                .font(.label12)
                .foregroundStyle(heroInk.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: heroFill)
    }

    /// Unlike Who Am I?, the answer's photo rides in the content itself (`journeyman.py` reads
    /// it off the same catalog rows it builds the path from), so there's no reveal-time catalog
    /// search and no chance of showing a same-name player's face.
    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PlayerHeadshotBadge(headshot: puzzle.headshot, tint: Color.onAccent, size: 44,
                                    name: puzzle.answer.canonical)
                VStack(alignment: .leading, spacing: 1) {
                    Text("THE ANSWER WAS")
                        .font(.label11)
                        .foregroundStyle(Color.onAccent.opacity(0.75))
                    Text(puzzle.answer.canonical)
                        .font(.custom(FontName.condBlack, size: 20))
                        .foregroundStyle(Color.onAccent)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color.accentFill)
            HStack(spacing: 6) {
                Text(puzzle.sport.displayName)
                if let position = puzzle.position, !position.isEmpty {
                    Text("·")
                    Text(position)
                }
            }
            .font(.label11)
            .foregroundStyle(Color.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(Color.borderInk, lineWidth: 2))
    }

    /// The path again, next to the name it belonged to. Nothing was hidden during play, so this
    /// isn't a reveal — it's the board and the answer in one frame, which is the thing a player
    /// who just missed it actually wants to look at.
    private var fullPath: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THE PATH")
                .font(.label11)
                .foregroundStyle(Color.textMuted)
            CareerPathTimeline(sport: puzzle.sport, stints: puzzle.stints,
                               truncated: puzzle.truncated ?? false)
        }
    }

    /// Emoji row = guesses spent: ⬛ per wrong name, 🟩 on the one that landed (nothing green
    /// means it was never solved). Says how close someone came while leaking nothing about which
    /// player — the same spoiler rule `WhoAmIResultView.emojiClues` follows, and the reason
    /// neither this nor `shareText` ever touches `puzzle.answer` or a club name.
    static func emojiPath(result: JourneymanScoring.Result) -> String {
        let total = JourneymanScoring.maxGuesses
        let used = max(1, min(result.guessesUsed, total))
        return (1...total).map { i -> String in
            if result.solved && i == used { return "🟩" }
            return i <= used ? "⬛" : "⬜"
        }.joined()
    }

    /// `hits` is guess efficiency — guesses *not* needed, plus one — so naming it sooner wins,
    /// and the difficulty multiplier (a content property, not a performance) stays out of
    /// deciding a head-to-head. Same conversion rule as `ChallengeLink.whoAmIHits`.
    static func challengeLink(puzzle: JourneymanPuzzle, result: JourneymanScoring.Result,
                              date: Date = Date(), challenger: String? = nil) -> ChallengeLink {
        ChallengeLink(format: .journeyman, sport: puzzle.sport,
                      day: PuzzleStore.localDayString(date),
                      hits: ChallengeLink.journeymanHits(result),
                      outOf: ChallengeLink.journeymanOutOf,
                      score: result.total, challenger: challenger)
    }

    /// What lands in the share sheet. Pure so the exact text is locked by tests — same contract
    /// as the other three formats' `shareText`.
    static func shareText(puzzle: JourneymanPuzzle, result: JourneymanScoring.Result,
                          date: Date = Date(), isDaily: Bool = true,
                          challenger: String? = nil, now: Date = Date()) -> String {
        let board = emojiPath(result: result)
        let link = challengeLink(puzzle: puzzle, result: result, date: date, challenger: challenger)
        guard isDaily else {
            let headline = result.solved
                ? "I named a \(puzzle.sport.displayName) Journeyman in \(result.guessesUsed) guess\(result.guessesUsed == 1 ? "" : "es")."
                : "A \(puzzle.sport.displayName) Journeyman beat me."
            return ShareMessage.compose(headline: headline, board: board,
                                        detail: "\(link.scoreLine), no spoilers, go find out who.",
                                        campaign: link.campaignToken)
        }
        return link.shareText(board: board, now: now)
    }

    private var shareRow: some View {
        let card = JourneymanShareCardView(sport: puzzle.sport, result: result)
        return ShareLink(item: Self.shareText(puzzle: puzzle, result: result, isDaily: isDaily,
                                              challenger: container.identity.username),
                         preview: SharePreview(isDaily ? "Journeyman challenge" : "My Journeyman result",
                                               image: card.rendered())) {
            Label(isDaily ? "CHALLENGE A FRIEND" : "SHARE (NO SPOILERS)",
                  systemImage: "square.and.arrow.up").ctaLabel()
        }
        .buttonStyle(PrimePressStyle())
        .simultaneousGesture(TapGesture().onEnded {
            container.track(.shareTapped, AnalyticsEvent.shareProperties(
                surface: "journeyman_result", format: "journeyman", artifact: .challengeText,
                extra: ["sport": puzzle.sport.rawValue, "solved": String(result.solved),
                        "is_daily": String(isDaily)]))
        })
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            HStack(spacing: 12) {
                Button(action: onDone) {
                    Text("DONE")
                        .font(.heading)
                        .foregroundStyle(Color.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                if let ladderRematch {
                    RematchButton(rematching: $rematching, action: ladderRematch)
                }
            }
            .padding(16)
            .background(Color.surface)
        }
    }
}

/// Shareable result image — takes only `sport` and `result`, never the puzzle, so it is
/// structurally impossible for this card to leak the player or a single club of their path.
struct JourneymanShareCardView: View {
    let sport: Sport
    let result: JourneymanScoring.Result

    private var rare: Bool { result.solved && result.guessesUsed == 1 }
    private var ink: Color { rare ? .onVolt : .onAccent }

    var body: some View {
        ShareCardFrame {
            ShareCardHeaderBand(rare: rare) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Wordmark(size: 20)
                        Spacer()
                        Text("\(sport.displayName) · JOURNEYMAN")
                            .font(.custom(FontName.condBlack, size: 12))
                            .foregroundStyle(ink.opacity(0.85))
                    }
                    Text(result.solved ? (rare ? "FIRST-GUESS GENIUS" : "SOLVED") : "OUT OF GUESSES")
                        .font(.custom(FontName.condBlack, size: 22)).foregroundStyle(ink)
                    Text("\(result.total)").font(.hero(36)).foregroundStyle(ink)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(JourneymanResultView.emojiPath(result: result))
                    .font(.system(size: 30))
                Text(result.solved
                     ? "NAMED ON GUESS \(result.guessesUsed) OF \(JourneymanScoring.maxGuesses)"
                     : "BETTER LUCK TOMORROW")
                    .font(.custom(FontName.condBold, size: 13))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface1)

            ShareCardFooter()
        }
    }

    @MainActor
    func rendered(scale: CGFloat = 3) -> Image { renderedForShare(scale: scale) }
}
