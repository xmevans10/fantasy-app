import SwiftUI

/// One revealed Who Am I? clue: numbered chip in the clue family's color, label over text.
///
/// Shared by the game board and the X post renderer (`XPostRenderTests`), so a post shows the
/// row a player actually reads rather than an imitation of it.
struct WhoAmIClueRow: View {
    let clue: WhoAmIPuzzle.Clue

    var body: some View {
        let family = ClueFamily.of(clue)
        HStack(alignment: .top, spacing: 12) {
            Text("\(clue.order)")
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(family.onChip)
                .frame(width: 26, height: 26)
                .background(family.chipFill)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(clue.displayLabel)
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                Text(clue.text)
                    .font(.body14)
                    .foregroundStyle(Color.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// An unbought clue slot. Rendered from the first frame so the board is the same shape at
/// clue 1 as at clue 6 — at the opening state 53.5% of this screen used to be empty page
/// background and at the close only 3.7% was, so there was never one fixed thing that could
/// fill it. The five unbought clues are that thing.
///
/// Carries the position and the price and **nothing else**. The clue's own label would leak
/// its dimension ("Last team" on slot 5 answers slot 5), which is the one thing this screen
/// may never do. Position and price are pure functions of the clue index and the difficulty
/// tier, and the tier is already printed in the header, so this reveals nothing new.
///
/// Deliberately **not tappable**: the "Next clue" button stays the only purchase path, so
/// clues can't be bought out of order — `revealedCount` means "the first N clues", and every
/// score derived from it assumes exactly that.
struct WhoAmILockedClueRow: View {
    let position: Int
    /// Already formatted by the caller: points solo, a share of the board inside a blitz.
    let costText: String
    let accessibilityText: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(position)")
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(Color.textDisabled)
                .frame(width: 26, height: 26)
                .background(Color.surfaceMuted)
                .clipShape(Circle())
            // Two lines, mirroring `WhoAmIClueRow`'s label+text stack on purpose: it makes a
            // locked row exactly as tall as a one-line revealed row, so the ladder is even and
            // buying a clue never jumps the rows below it.
            VStack(alignment: .leading, spacing: 2) {
                Text("Locked")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                Text(costText)
                    .font(.body14)
                    .foregroundStyle(Color.textDisabled)
            }
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
