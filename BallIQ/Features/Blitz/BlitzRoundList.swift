import SwiftUI

/// Every board of a finished run, in play order — **what it asked, and whether you got it**.
///
/// This used to be a list of scoring arithmetic: tap a row and it unfolded quality-vs-chance,
/// board value, base and combo, four lines explaining how a number was reached. That answers a
/// question nobody has. Coming off a blitz you want to know *what the answer was* — the name you
/// couldn't place, the line you called wrong — and whether you got it. The points are already on
/// the row; the derivation behind them was noise wearing the clothes of transparency.
///
/// So the answer is the row now, there is nothing to expand, and the arithmetic is gone. What
/// each board can say about itself comes from `BlitzRoundAnswer`, supplied by that format's own
/// game view at `finishRound` — only the board knows its answer, since `performance` is a number
/// and cannot be turned back into a player's name.
///
/// The one figure kept from the old detail is the combo marker, because it is the only thing on
/// this screen a player could have acted on during the run. Points still come off
/// `BlitzScoring.RoundBreakdown` rather than being recomputed, so the rows still sum to the
/// headline by construction.
struct BlitzRoundList: View {
    let summary: BlitzRunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EVERY PUZZLE").font(.label12).foregroundStyle(Color.accentText)

            VStack(spacing: 0) {
                ForEach(Array(summary.breakdown.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(Color.hairline).frame(height: Hairline.width) }
                    roundRow(index: index, row: row)
                }
                if let cutOff = summary.cutOff {
                    Rectangle().fill(Color.hairline).frame(height: Hairline.width)
                    cutOffRow(cutOff, index: summary.breakdown.count)
                }
            }
            .cardSurface()
        }
    }

    // MARK: - Rows

    private func roundRow(index: Int, row: BlitzScoring.RoundBreakdown) -> some View {
        HStack(spacing: 10) {
            formatBadge(row.round.format)

            VStack(alignment: .leading, spacing: 2) {
                // The answer leads. Falling back to the format's name keeps a round recorded
                // before answers existed — or replayed from a bot, which has none — readable
                // rather than blank.
                Text(row.round.answer?.headline ?? row.round.format.displayName)
                    .font(.bodyStrong).foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let detail = row.round.answer?.detail {
                        Text(detail)
                    } else {
                        Text(row.round.sport.displayName.uppercased())
                    }
                    if row.comboApplied {
                        Text("·")
                        Text(String(format: "×%.1f", row.combo))
                            .foregroundStyle(Color.accentText)
                    }
                }
                .font(.label11)
                .foregroundStyle(Color.textMuted)
            }

            Spacer(minLength: 8)
            outcomePill(row)
            Text(signed(row.points))
                .font(.custom(FontName.condBlack, size: 17))
                .monospacedDigit()
                .foregroundStyle(row.points < 0 ? Color.dangerText : Color.textPrimary)
                .frame(minWidth: 46, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel(index: index, row: row)))
    }

    /// The board the clock caught. Deliberately styled as an absence — no points column, muted
    /// throughout — because it is the one row on this screen that is not a score.
    private func cutOffRow(_ cutOff: BlitzCutOff, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cutOff.format.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.textMuted)
                .frame(width: 26, height: 26)
                .background(Color.hairline)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(cutOff.format.displayName)
                    .font(.bodyStrong).foregroundStyle(Color.textMuted).lineLimit(1)
                Text("\(cutOff.sport.displayName.uppercased()) · CUT OFF BY THE CLOCK")
                    .font(.label11).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 8)
            Text("NOT SCORED").font(.label11).foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized:
            "Puzzle \(index + 1), \(cutOff.format.displayName), cut off by the clock, not scored")))
    }

    // MARK: - Pieces

    private func formatBadge(_ format: BlitzFormat) -> some View {
        Image(systemName: format.symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(format.onTint)
            .frame(width: 26, height: 26)
            .background(format.tint)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Right / wrong, as a shape as well as a colour — the two states have to survive a
    /// colour-blind reader and a greyscale screenshot.
    private func outcomePill(_ row: BlitzScoring.RoundBreakdown) -> some View {
        Image(systemName: row.round.cleared ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(row.round.cleared ? Color.successText : Color.dangerText)
            .accessibilityHidden(true)
    }

    // MARK: - Formatting

    /// Points carry their sign: a negative round is the one a player most wants explained, and
    /// "-120" reading as "120" would make the list fail to reconcile against the total.
    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    /// Reads the row the way the screen does — the answer first, then right or wrong.
    private func accessibilityLabel(index: Int, row: BlitzScoring.RoundBreakdown) -> String {
        let outcome = row.round.cleared ? String(localized: "correct") : String(localized: "wrong")
        let headline = row.round.answer?.headline ?? row.round.format.displayName
        let detail = row.round.answer?.detail.map { ", \($0)" } ?? ""
        return String(localized:
            "Puzzle \(index + 1), \(headline)\(detail), \(outcome), \(row.points) points")
    }
}
