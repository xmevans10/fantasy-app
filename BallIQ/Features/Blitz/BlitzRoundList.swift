import SwiftUI

/// Every board of a finished run, in play order, each one openable to show how it was scored.
///
/// **Why this exists alongside the per-format breakdown.** "Where it came from" answers *which
/// format* paid, which is the right first question but the wrong last one: a run of eleven boards
/// collapses into four rows there, and the board a player actually wants to argue with — the one
/// they thought they nailed and got 40 points for — is invisible. This lists all of them and,
/// on tap, shows the arithmetic that produced the number.
///
/// **Every figure is read off `BlitzScoring.RoundBreakdown`, never recomputed here.** A round's
/// points depend on the combo it landed on, which is a property of the sequence, so a view that
/// derived its own would be re-implementing a fold it cannot see the whole of. That is also why
/// the rows sum to the headline: they are the same fold.
struct BlitzRoundList: View {
    let summary: BlitzRunSummary

    /// Which round is open. One at a time — this sits inside the result screen's scroll view, and
    /// letting several expand turns a scannable list into a page of arithmetic nobody asked for.
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("EVERY PUZZLE").font(.label12).foregroundStyle(Color.accentText)
                Spacer(minLength: 8)
                Text("TAP FOR DETAIL").font(.label11).foregroundStyle(Color.textMuted)
            }

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
        let isOpen = expanded == row.id
        return VStack(spacing: 0) {
            Button {
                Haptics.tap()
                withAnimation(Motion.easeOut) { expanded = isOpen ? nil : row.id }
            } label: {
                HStack(spacing: 10) {
                    formatBadge(row.round.format)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.round.format.displayName)
                            .font(.bodyStrong).foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(row.round.sport.displayName.uppercased())
                            Text("·")
                            Text(String(format: "%.0fs", row.round.elapsed))
                            if row.comboApplied {
                                Text("·")
                                // The combo is the one thing a player can act on mid-run, so it
                                // gets a marker in the collapsed row rather than only inside.
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
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityLabel(index: index, row: row)))
            .accessibilityHint(Text(isOpen ? String(localized: "Hides the scoring detail")
                                           : String(localized: "Shows how this puzzle was scored")))

            if isOpen { detail(row) }
        }
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

    // MARK: - Expanded detail

    /// The arithmetic, in the order it happens: quality, then what that is worth, then the combo.
    private func detail(_ row: BlitzScoring.RoundBreakdown) -> some View {
        VStack(spacing: 8) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)

            VStack(spacing: 7) {
                detailLine(String(localized: "Quality vs chance"), percent(row.surplus),
                           note: qualityNote(row))
                detailLine(String(localized: "Board value"),
                           "\(BlitzScoring.maxRoundPoints(row.round.format))",
                           note: String(localized: "\(Int(row.round.format.parSeconds))s par at \(Int(BlitzScoring.pointsPerParSecond))/s"))
                detailLine(String(localized: "Base"), signed(Int(row.base.rounded())),
                           note: String(localized: "Value × quality"))
                if row.comboApplied {
                    detailLine(String(localized: "Combo"), String(format: "×%.1f", row.combo),
                               note: row.consecutiveCleared == 1
                                   ? String(localized: "1 clean board before this")
                                   : String(localized: "\(row.consecutiveCleared) clean boards before this"),
                               highlight: true)
                }
                Rectangle().fill(Color.hairline).frame(height: Hairline.width)
                detailLine(String(localized: "Scored"), signed(row.points), note: nil, bold: true)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .padding(.top, 2)
        }
        .transition(.opacity)
    }

    private func detailLine(_ label: String, _ value: String, note: String?,
                            highlight: Bool = false, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(bold ? .bodyStrong : .label12)
                    .foregroundStyle(bold ? Color.textPrimary : Color.textMuted)
                if let note {
                    Text(note).font(.label11).foregroundStyle(Color.textMuted.opacity(0.8))
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.custom(FontName.condBlack, size: bold ? 17 : 14))
                .monospacedDigit()
                .foregroundStyle(highlight ? Color.accentText : Color.textPrimary)
        }
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

    /// Cleared / missed, as a shape as well as a colour — the two states have to survive a
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

    private func percent(_ surplus: Double) -> String {
        "\(Int((surplus * 100).rounded()))%"
    }

    private func qualityNote(_ row: BlitzScoring.RoundBreakdown) -> String {
        if row.surplus > 0 { return String(localized: "Better than a guess") }
        if row.surplus < 0 { return String(localized: "Worse than a guess") }
        return String(localized: "Level with a guess")
    }

    private func accessibilityLabel(index: Int, row: BlitzScoring.RoundBreakdown) -> String {
        let outcome = row.round.cleared ? String(localized: "cleared") : String(localized: "missed")
        return String(localized:
            "Puzzle \(index + 1), \(row.round.format.displayName), \(outcome), \(row.points) points")
    }
}
