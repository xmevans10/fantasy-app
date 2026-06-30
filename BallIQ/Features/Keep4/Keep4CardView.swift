import SwiftUI

struct Keep4CardView: View {
    let player: PlayerSeason
    /// Drives the team-color header band.
    var sport: Sport = .nfl
    let assignment: Pile?
    /// Set after submit to reveal correctness; nil during play.
    let revealCorrect: Bool?
    /// Hard mode hides stat values during play (results always reveal them).
    var hideStats: Bool = false
    /// In the blind game, the full pile is forced-disabled (you can only pick the other one).
    var disabledPile: Pile? = nil
    /// "Rare/foil" holographic treatment — used on the single top season in the result reveal.
    var foil: Bool = false
    let onAssign: (Pile) -> Void

    @State private var dragX: CGFloat = 0
    private let commitThreshold: CGFloat = 70

    private var team: TeamPalette { TeamColors.palette(sport: sport, abbr: player.teamAbbr) }
    private var isLocked: Bool { revealCorrect != nil }

    // The outline color flips on reveal to broadcast correctness, else stays ink.
    private var outline: Color {
        if let revealCorrect { return revealCorrect ? .successFill : .dangerFill }
        return .borderInk
    }

    private var dragTint: Color? {
        if dragX > commitThreshold { return .successFill }
        if dragX < -commitThreshold { return .dangerFill }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            teamBand
            statRow
            if !isLocked {
                segmentedControl.padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
            } else if let revealCorrect {
                verdict(revealCorrect).padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 4)
            }
        }
        .background(dragTint?.opacity(0.10) ?? Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foil(active: foil, cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(outline, lineWidth: 3)
        )
        .background(   // hard offset "ledge" shadow, sticker/comic pop
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.borderInk)
                .offset(x: 5, y: 5)
        )
        .offset(x: dragX)
        .gesture(isLocked ? nil : dragGesture)
        .animation(Motion.snap, value: dragX)
        .animation(Motion.easeOut, value: assignment)
        .animation(Motion.easeOut, value: revealCorrect)
    }

    // MARK: - Team-color band

    private var teamBand: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.name.uppercased())
                    .font(.custom(FontName.condBlack, size: 21))
                    .foregroundStyle(team.onPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(player.subtitle.uppercased())
                    .font(.custom(FontName.condBold, size: 12))
                    .foregroundStyle(team.onPrimary.opacity(0.72))
            }
            Spacer(minLength: 6)
            // The grade is the hidden number players sort on — only reveal it post-submit.
            if isLocked { gradeChip }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(team.primary)
    }

    /// The quality grade, shown only on reveal (never during selection — it's the answer).
    private var gradeChip: some View {
        let onSecondary: Color = team.onPrimary == .white ? Color(hex: 0x15120B) : .white
        return VStack(spacing: 0) {
            Text("\(Int(player.grade.rounded()))")
                .font(.hero(24))
                .foregroundStyle(onSecondary)
            Text("GRADE")
                .font(.custom(FontName.condBold, size: 9))
                .foregroundStyle(onSecondary.opacity(0.8))
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(team.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var statRow: some View {
        HStack(spacing: 16) {
            ForEach(player.stats, id: \.label) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(hideStats ? "—" : stat.value)
                        .font(.custom(FontName.condBlack, size: 22))
                        .foregroundStyle(hideStats ? Color.textMuted : Color.textPrimary)
                    Text(stat.label.uppercased())
                        .font(.label11)
                        .foregroundStyle(Color.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, isLocked ? 0 : 6)
    }

    private func verdict(_ correct: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
            Text(assignment == .keep ? "You kept" : "You cut")
                .font(.custom(FontName.condBold, size: 14))
        }
        .foregroundStyle(correct ? Color.successText : Color.dangerText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Controls

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            segment(title: "Cut", pile: .cut, color: .dangerFill, on: .onDanger)
            segment(title: "Keep", pile: .keep, color: .successFill, on: .onSuccess)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
    }

    private func segment(title: String, pile: Pile, color: Color, on: Color) -> some View {
        let active = assignment == pile
        let disabled = disabledPile == pile
        return Button {
            guard !disabled else { return }
            onAssign(pile)
        } label: {
            Text(title.uppercased())
                .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 15))
                .foregroundStyle(active ? on : Color.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(active ? color : Color.surfaceMuted)
                .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragX = value.translation.width }
            .onEnded { value in
                let dx = value.translation.width
                if dx > commitThreshold, disabledPile != .keep {
                    onAssign(.keep)
                } else if dx < -commitThreshold, disabledPile != .cut {
                    onAssign(.cut)
                }
                dragX = 0
            }
    }
}
