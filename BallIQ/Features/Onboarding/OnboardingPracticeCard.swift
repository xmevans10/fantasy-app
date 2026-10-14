import SwiftUI

/// The how-to-play step used to just list K4C4's three rules as static text. This is the same
/// lesson taught by doing: one real bundled puzzle, one card dealt, one keep/cut call. The
/// player learns the gesture and sees a graded verdict before they ever open the real board.
///
/// Offline only (bundled `PuzzleStore`, no `RepositoryContainer`) because onboarding's how-to-play
/// step renders while the real daily puzzle is still loading in the background (see
/// `OnboardingView.loadFirstPuzzle`) — this card can't wait on that fetch or on network at all.
///
/// This slide sits on `OnboardingChrome`'s red `.slideBackdrop`, so the header lives on a solid
/// color block — headline text uses `.onDanger` (white), not `.textPrimary`, or it disappears.
struct OnboardingPracticeCard: View {
    let sport: Sport
    /// Called once, after the player's call is revealed.
    var onPracticed: () -> Void = {}

    @State private var deal: Deal
    @State private var assignment: Pile?
    @State private var revealCorrect: Bool?
    @State private var showGrade = false
    @State private var celebrateTrigger = 0
    @State private var hasFiredOnPracticed = false
    /// The KEPT!/CUT! stamp slams onto the card first; the verdict prose waits a beat so the two
    /// don't land as one blur of motion (broadcast graphics never fire the sting and the caption
    /// in the same frame).
    @State private var verdictVisible = false
    @State private var cardPulse = false
    @State private var cardShake: CGFloat = 0
    /// Correct calls across every "Try another" deal in this session, not just the current one —
    /// the chip is a running practice score, so it must survive `redeal()`.
    @State private var correctCount = 0
    @State private var attemptCount = 0
    @State private var chipPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(sport: Sport, onPracticed: @escaping () -> Void = {}) {
        self.sport = sport
        self.onPracticed = onPracticed
        _deal = State(initialValue: Deal.first(for: sport))
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            if deal.puzzle != nil, let player = deal.player {
                card(player: player)
                Group {
                    if let revealCorrect, verdictVisible {
                        verdictLine(correct: revealCorrect, player: player)
                    } else if revealCorrect == nil {
                        Text("1 of 8 cards on this board. Swipe to make your call.")
                            .font(.label12)
                            .foregroundStyle(Color.textMuted)
                    } else {
                        // Verdict is queued behind the stamp landing — hold the row's height so
                        // the controls below don't hop up and back down in that gap.
                        Color.clear.frame(height: 1)
                    }
                }
                .heroReveal(2)
                controlsRow
            }
            // No bundled content for any sport should not happen with the shipped catalog, but a
            // placeholder card would be worse than an honest, quiet skip.
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("K4C4")
                .font(.hero(44))
                .foregroundStyle(Color.onDanger)
            PopStamp(text: "KEEP 4 · CUT 4", fill: .voltFill, on: .onVolt, angle: -5, size: 15)
            Text("Swipe right to keep, left to cut. Keep the four seasons that scored the most.")
                .font(.label12)
                .foregroundStyle(Color.onDanger.opacity(0.92))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .heroReveal(0)
    }

    // MARK: - Card

    private func card(player: PlayerSeason) -> some View {
        let unit = deal.puzzle?.scoringKind().gradeUnit ?? "PTS"
        return DealtCard {
            Keep4CardView(player: player,
                          sport: deal.puzzle?.sport ?? sport,
                          assignment: assignment,
                          revealCorrect: revealCorrect,
                          gradeUnit: unit,
                          showGrade: showGrade,
                          teamFullName: nil) { pile in
                commit(pile, player: player)
            }
        }
        .frame(maxWidth: 420)
        .frame(height: 250)
        .overlay(alignment: .topLeading) {
            PopStamp(text: "PRACTICE", angle: -10, size: 13)
                .offset(x: -8, y: -14)
        }
        .overlay {
            if let assignment {
                callStamp(for: assignment)
            }
        }
        .scaleEffect(cardPulse ? 1.05 : 1)
        .offset(x: cardShake)
        // A fresh identity per deal: without it "Try another" reused the previous card's view
        // state, so the new season rendered under the old player's headshot and drag offset. It
        // also resets `DealtCard`'s entrance animation, so every redeal slams in the same way.
        .id(player.id)
        .heroReveal(1)
    }

    /// The big rotated call-out for the player's actual swipe — green "KEPT!" or red "CUT!" —
    /// independent of whether the call was right. Correctness is what the verdict line below
    /// judges; this stamp just broadcasts what happened.
    private func callStamp(for pile: Pile) -> some View {
        PopStamp(text: pile == .keep ? "KEPT!" : "CUT!",
                  fill: pile == .keep ? .successFill : .dangerFill,
                  on: pile == .keep ? .onSuccess : .onDanger,
                  angle: pile == .keep ? -12 : 10,
                  size: 28)
    }

    private func commit(_ pile: Pile, player: PlayerSeason) {
        guard assignment == nil, let puzzle = deal.puzzle else { return }
        let shouldKeep = puzzle.correctKeepIDs.contains(player.id)
        let correct = (pile == .keep && shouldKeep) || (pile == .cut && !shouldKeep)

        assignment = pile
        revealCorrect = correct
        showGrade = true
        attemptCount += 1

        if correct {
            correctCount += 1
            Haptics.success()
            celebrateTrigger += 1
            pulseCard()
            pulseChip()
        } else {
            Haptics.reject()
            shakeCard()
        }
        revealVerdict()

        if !hasFiredOnPracticed {
            hasFiredOnPracticed = true
            onPracticed()
        }
    }

    private func revealVerdict() {
        guard !reduceMotion else { verdictVisible = true; return }
        verdictVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(Motion.easeOut) { verdictVisible = true }
        }
    }

    private func pulseCard() {
        guard !reduceMotion else { return }
        withAnimation(Motion.snap) { cardPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(Motion.snap) { cardPulse = false }
        }
    }

    /// Inline offset animation, same shape as `WhoAmIGameView`'s wrong-guess shake, so a rejected
    /// call reads the same "no" across both games.
    private func shakeCard() {
        guard !reduceMotion else { return }
        withAnimation(Motion.snap) { cardShake = -8 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(Motion.snap) { cardShake = 8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(Motion.snap) { cardShake = 0 }
        }
    }

    private func pulseChip() {
        guard !reduceMotion else { return }
        withAnimation(Motion.overshoot) { chipPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(Motion.snap) { chipPulse = false }
        }
    }

    private func verdictLine(correct: Bool, player: PlayerSeason) -> some View {
        let unit = deal.puzzle?.scoringKind().gradeUnit ?? "PTS"
        let points = player.gradeText
        let shouldKeep = deal.puzzle?.correctKeepIDs.contains(player.id) == true
        let text: String
        switch (correct, shouldKeep) {
        case (true, true):
            text = String(localized: "Nailed it. \(points) \(unit), a top-four season on this board.")
        case (true, false):
            text = String(localized: "Good cut. \(points) \(unit), a bottom-four season on this board.")
        case (false, true):
            text = String(localized: "\(points) \(unit). That one was a keep. In the real game every call is final.")
        case (false, false):
            text = String(localized: "\(points) \(unit). That one was a cut. In the real game every call is final.")
        }
        return HStack(spacing: 6) {
            Image(systemName: correct ? "checkmark.seal.fill" : "info.circle.fill")
            Text(text)
        }
        .font(.custom(FontName.condBold, size: 13))
        .foregroundStyle(correct ? Color.successText : Color.textMuted)
        .multilineTextAlignment(.leading)
        .celebrate(on: $celebrateTrigger)
    }

    // MARK: - Controls

    /// Score chip and "Try another" share a row instead of stacking — the chip only earns its
    /// keep once there's a score to show, and the row costs no extra height over the old
    /// underlined-text link this replaced.
    private var controlsRow: some View {
        HStack(spacing: 10) {
            if attemptCount > 0 {
                scoreChip
            }
            Spacer(minLength: 0)
            tryAnother
        }
    }

    private var scoreChip: some View {
        HStack(spacing: 4) {
            Text("PRACTICE \(correctCount)/\(attemptCount)")
                .font(.custom(FontName.condBold, size: 12))
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.surface1)
                .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 2))
        )
        .scaleEffect(chipPulse ? 1.16 : 1)
    }

    private var tryAnother: some View {
        Button {
            Haptics.tap()
            withAnimation(reduceMotion ? nil : Motion.easeOut) {
                deal = deal.next()
                assignment = nil
                revealCorrect = nil
                showGrade = false
                verdictVisible = false
            }
            cardPulse = false
            cardShake = 0
        } label: {
            Text("Try another")
                .font(.custom(FontName.condBold, size: 14))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .buttonStyle(LedgePressStyle(fill: .surface1, lift: 4, radius: 12))
    }

    // MARK: - Deal

    /// One puzzle + one chosen player from it, plus enough state to cycle to the "next" deal
    /// deterministically (no `Int.random` — a fresh reload of this screen should behave the
    /// same way twice in a row).
    private struct Deal {
        let puzzle: Keep4Puzzle?
        /// The candidates this puzzle offers to practice on: the clearest keep, then the clearest
        /// cut, then the next of each. Alternating matters: an all-keeper deck teaches "always
        /// swipe right", which is the one lesson a keep/cut game must not teach.
        let candidates: [PlayerSeason]
        var candidateIndex: Int

        var player: PlayerSeason? {
            guard !candidates.isEmpty else { return nil }
            return candidates[candidateIndex % candidates.count]
        }

        /// First deal for a sport: today's puzzle for that sport (falling back to any sport if
        /// the pool is thin), opening on the top-graded season, the least arguable keep on the
        /// board (`correctKeepIDs` is exactly the top four).
        static func first(for sport: Sport) -> Deal {
            let store = PuzzleStore.shared
            let puzzle = store.todaysPuzzle(for: sport) ?? store.todaysPuzzle(for: nil)
            guard let puzzle else { return Deal(puzzle: nil, candidates: [], candidateIndex: 0) }
            let keepers = puzzle.players
                .filter { puzzle.correctKeepIDs.contains($0.id) }
                .sorted { $0.grade > $1.grade }
            let cutters = puzzle.players
                .filter { !puzzle.correctKeepIDs.contains($0.id) }
                .sorted { $0.grade < $1.grade }
            var interleaved: [PlayerSeason] = []
            for i in 0..<max(keepers.count, cutters.count) {
                if i < keepers.count { interleaved.append(keepers[i]) }
                if i < cutters.count { interleaved.append(cutters[i]) }
            }
            return Deal(puzzle: puzzle, candidates: interleaved, candidateIndex: 0)
        }

        /// "Try another": the next card in the keep/cut alternation, wrapping once exhausted.
        func next() -> Deal {
            guard puzzle != nil, !candidates.isEmpty else { return self }
            var copy = self
            copy.candidateIndex = (candidateIndex + 1) % candidates.count
            return copy
        }
    }
}

/// Wraps the dealt card with a one-shot overshoot entrance — slide up plus a slight rotation that
/// settles — owned here (not inline) because the animation needs its own `@State` that resets
/// with the card's `.id(player.id)`; state living on the parent view wouldn't replay per deal.
private struct DealtCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var isIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .offset(y: (isIn || reduceMotion) ? 0 : 46)
            .rotationEffect(.degrees((isIn || reduceMotion) ? 0 : -7))
            .onAppear {
                guard !reduceMotion else { isIn = true; return }
                withAnimation(Motion.overshoot) { isIn = true }
            }
    }
}

#Preview {
    ScrollView {
        OnboardingPracticeCard(sport: .nfl)
            .padding(16)
    }
    .paperGround()
}
