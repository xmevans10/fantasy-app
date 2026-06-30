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
            statGrid
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
        HStack(alignment: .center, spacing: 11) {
            headshotView
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
            // Team logo during play; the grade (the hidden sort number) replaces it on reveal.
            if isLocked { gradeChip } else { teamLogoView }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(team.primary)
    }

    /// ESPN team-logo CDN, keyed by sport + lowercase abbreviation (all our abbrs resolve).
    private var teamLogoURL: URL? {
        let abbr = player.teamAbbr.lowercased()
        guard !abbr.isEmpty else { return nil }
        let league = sport == .nfl ? "nfl" : "nba"
        return URL(string: "https://a.espncdn.com/i/teamlogos/\(league)/500/\(abbr).png")
    }

    @ViewBuilder private var teamLogoView: some View {
        if let url = teamLogoURL {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFit() } else { Color.clear }
            }
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(0.15))   // faint disc, not a heavy white badge
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(team.onPrimary.opacity(0.35), lineWidth: 1))
        }
    }

    /// Player headshot (nflverse/ESPN) in a team-tinted circle; falls back to a glyph when absent.
    private var headshotView: some View {
        let fallback = Image(systemName: "person.fill")
            .font(.system(size: 22))
            .foregroundStyle(team.onPrimary.opacity(0.55))
        return Group {
            if let s = player.headshot, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: 48, height: 48)
        .background(team.onPrimary.opacity(0.15))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(team.onPrimary.opacity(0.25), lineWidth: 1))
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

    private static let statColumns = Array(
        repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3)

    /// Stats in a 3-wide grid so a fuller line (5+ stats, incl. QB rushing) reads cleanly
    /// and the card uses its vertical canvas instead of one cramped row.
    private var statGrid: some View {
        LazyVGrid(columns: Self.statColumns, alignment: .leading, spacing: 10) {
            ForEach(player.stats, id: \.label) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(hideStats ? "—" : stat.value)
                        .font(.custom(FontName.condBlack, size: 19))
                        .foregroundStyle(hideStats ? Color.textMuted : Color.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(stat.label.uppercased())
                        .font(.label11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, isLocked ? 2 : 8)
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

    private static let cutGradient = LinearGradient(
        colors: [Color(hex: 0xFF5B4A), Color(hex: 0xC41F14)], startPoint: .top, endPoint: .bottom)
    private static let keepGradient = LinearGradient(
        colors: [Color(hex: 0x2BD27A), Color(hex: 0x12923F)], startPoint: .top, endPoint: .bottom)

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            segment(title: "Cut", pile: .cut, gradient: Self.cutGradient)
            segment(title: "Keep", pile: .keep, gradient: Self.keepGradient)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
    }

    /// Both sides always carry their color (red Cut / green Keep) as a gradient; the picked
    /// side goes full-strength while the other dims, so the choice still reads at a glance.
    private func segment(title: String, pile: Pile, gradient: LinearGradient) -> some View {
        let active = assignment == pile
        let disabled = disabledPile == pile
        return Button {
            guard !disabled else { return }
            onAssign(pile)
        } label: {
            Text(title.uppercased())
                .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 15))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(gradient)
                .opacity(disabled ? 0.3 : (active || assignment == nil ? 1 : 0.5))
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
