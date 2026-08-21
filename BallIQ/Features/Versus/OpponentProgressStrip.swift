import SwiftUI

/// The opponent's live progress in a race (M23) — how many guesses they've burned and whether
/// they're done, never what any of those guesses were.
///
/// Takes only counts and booleans, on purpose: there is no `guessedName` parameter to wire up,
/// so a wrong name genuinely cannot leak through this view no matter what a future call site
/// tries to pass it. M23 §1 is explicit about why — "a wrong name is a hint", and handing one
/// player another's eliminations turns the race into a collaboration. If a future format's board
/// wants richer opponent telemetry, that's a new, separately-considered surface, not a parameter
/// added here.
struct OpponentProgressStrip: View {
    let opponentName: String?
    /// Guesses spent so far, out of `maxGuesses`. The poll always reports a count (0 counts),
    /// so this is never "unknown" once `LiveDuelSession.state` has landed once.
    let guesses: Int
    let maxGuesses: Int
    /// Out of guesses, or gave up — the race stays open (M23 §1: "the game stays open until the
    /// opponent finishes or the clock expires"), so this is a status, not an ending.
    let finished: Bool
    /// The opponent found the answer — the one state that ends the whole duel the instant the
    /// server sees it. `JourneymanGameView` reads `LiveDuelSession.opponentAlreadyWon` (which
    /// folds this together with the row's own resolution) to decide when to close the local
    /// board; this view only ever renders what's already true.
    let solved: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: solved ? "bolt.fill" : "person.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(solved ? Color.dangerText : Color.textMuted)
            Text(opponentName ?? String(localized: "Opponent"))
                .font(.label12)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            pips
            Spacer(minLength: 8)
            Text("\(guesses)/\(maxGuesses)")
                .font(.custom(FontName.condBlack, size: 14))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(solved ? Color.dangerText : Color.textPrimary)
            if solved || finished {
                Text(solved ? "SOLVED" : "OUT")
                    .font(.label11)
                    .foregroundStyle(solved ? Color.onDanger : Color.onAccent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(solved ? Color.dangerFill : Color.textMuted)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.surfaceMuted)
        .animation(Motion.snap, value: guesses)
        .animation(Motion.snap, value: solved)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// One pip per guess, filled left to right as they're spent — the shape of the local
    /// player's own guess bar (`JourneymanGameView`'s "N guesses left" line), so the two read as
    /// the same race rather than two different vocabularies.
    private var pips: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(0, maxGuesses), id: \.self) { index in
                Circle()
                    .fill(index < guesses
                          ? (solved ? Color.dangerFill : Color.textMuted)
                          : Color.borderStrong.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var accessibilityText: Text {
        let name = opponentName ?? String(localized: "Opponent")
        if solved { return Text("\(name) solved it") }
        if finished { return Text("\(name) is out of guesses, \(guesses) of \(maxGuesses) used") }
        return Text("\(name) has used \(guesses) of \(maxGuesses) guesses")
    }
}

#Preview {
    VStack(spacing: 1) {
        OpponentProgressStrip(opponentName: "hoopsfan", guesses: 0, maxGuesses: 5,
                              finished: false, solved: false)
        OpponentProgressStrip(opponentName: "hoopsfan", guesses: 2, maxGuesses: 5,
                              finished: false, solved: false)
        OpponentProgressStrip(opponentName: "averylongusernamehere", guesses: 5, maxGuesses: 5,
                              finished: true, solved: false)
        OpponentProgressStrip(opponentName: nil, guesses: 3, maxGuesses: 5,
                              finished: true, solved: true)
    }
    .background(Color.appBackground)
}
