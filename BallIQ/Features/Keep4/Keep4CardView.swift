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
    /// Unit under the revealed grade ("PTS" for fantasy totals).
    var gradeUnit: String = "PTS"
    /// Vibes puzzles have no formula and never show a number — the team logo stays put even
    /// on reveal instead of flipping to the grade chip.
    var showGrade: Bool = true
    /// Board play hands the card the whole canvas, so the stat sheet stretches to fill it
    /// rather than leaving a small card marooned in dead background (the deck used to occupy
    /// about a quarter of its own screen). Result/recap cards keep their compact intrinsic
    /// height — they sit in a scrolling column where growing would just push content down.
    var fillsHeight: Bool = false
    /// The franchise's real name ("Arizona Cardinals") for the band's second line. Supplied by
    /// the caller because it comes from `TeamIdentityIndex`, which warms asynchronously and is
    /// not observable — a card that looked it up itself would render whatever was in the index
    /// the first time it drew and never update. nil (cold launch, offline, a traded row with no
    /// team) simply drops the line; the code is still in the chip strip.
    var teamFullName: String? = nil
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
            statSheet
            if !isLocked {
                segmentedControl.padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 10)
            } else if let revealCorrect {
                verdict(revealCorrect).padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 10)
            }
        }
        .frame(maxHeight: fillsHeight ? .infinity : nil)
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
        // The drag gesture that commits Keep/Cut has no VoiceOver equivalent by itself; the tap
        // buttons in `segmentedControl` are the accessible fallback (labeled below). These rotor
        // actions are an *additional* shortcut mirroring what the drag does for sighted users —
        // additive, not a replacement for labeling the buttons themselves.
        .accessibilityAction(named: "Keep") { if !isLocked, disabledPile != .keep { onAssign(.keep) } }
        .accessibilityAction(named: "Cut") { if !isLocked, disabledPile != .cut { onAssign(.cut) } }
    }

    // MARK: - Team-color band

    /// On a full-height card the band is the piece that absorbs whatever room the stat sheet
    /// and the controls don't need — a bigger photo on a bigger field of team color, the way a
    /// physical card is mostly picture. Letting the *stats* absorb it instead is what the first
    /// pass at this did, and it just relocated the dead space into 150pt-tall tiles.
    @ViewBuilder private var teamBand: some View {
        if fillsHeight {
            GeometryReader { geo in
                bandContent(headshot: min(140, max(56, geo.size.height - 90)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(bandBackground)
        } else {
            bandContent(headshot: 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bandBackground)
        }
    }

    /// The team color as a *field*, not a flat block: a diagonal shade across it, broadcast
    /// stripes, and (on a full card) the crest blown up and cropped by the trailing edge.
    /// Every layer is derived from `team` — nothing here is a hardcoded color — and all of it
    /// keys off `onPrimary`, so a light-primary team (Vegas gold, Padres sand) gets dark
    /// texture where a dark-primary team gets light.
    private var bandBackground: some View {
        ZStack {
            team.primary
            LinearGradient(colors: [team.onPrimary.opacity(0.10), .clear,
                                    team.onPrimary.opacity(0.0), Color.black.opacity(0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            diagonalStripes
            if fillsHeight { crestWatermark }
        }
        .clipped()
    }

    /// Slanted broadcast bars. Drawn rather than assembled from rotated rectangles so the
    /// count adapts to whatever height the band ends up at.
    private var diagonalStripes: some View {
        Canvas { ctx, size in
            let stripe: CGFloat = 9
            let gap: CGFloat = 26
            var x = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + stripe, y: 0))
                path.addLine(to: CGPoint(x: x + stripe, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(team.onPrimary.opacity(0.055)))
                x += gap
            }
        }
        .allowsHitTesting(false)
    }

    /// The crest at card-art scale, bled off the trailing edge. Same badge the corner uses, so
    /// a defunct team with no crest degrades to its abbreviation here too instead of a hole.
    private var crestWatermark: some View {
        HStack {
            Spacer(minLength: 0)
            TeamLogoBadge(sport: sport, teamAbbr: player.teamAbbr, tint: team.onPrimary, size: 168,
                          // Drawn at 168, fetched at the badge size — see `fetchSize`. This is
                          // what lets the warm pass cover it.
                          fetchSize: 40)
                .opacity(0.15)
                .offset(x: 34, y: 14)
        }
        .allowsHitTesting(false)
    }

    private func bandContent(headshot: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: fillsHeight ? 14 : 11) {
                PlayerHeadshotBadge(headshot: player.headshot, tint: team.onPrimary,
                                    size: headshot, name: player.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.name.uppercased())
                        .font(.custom(FontName.condBlack, size: fillsHeight ? 26 : 21))
                        .foregroundStyle(team.onPrimary)
                        // One line even at the hero size: the two-line wrap put a 10pt leading
                        // gap between a first and last name and cost more than shrinking does.
                        .lineLimit(1).minimumScaleFactor(0.45)
                    // The franchise's real name, which the card never showed — it only ever had
                    // the three-letter code. Comes from the fetched `teams` row, so it is absent
                    // (not wrong) on a cold launch, and the code is still in the chip strip below.
                    if fillsHeight, let fullName = teamFullName {
                        Text(fullName.uppercased())
                            .font(.custom(FontName.condBold, size: 12))
                            .foregroundStyle(team.onPrimary.opacity(0.68))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if !fillsHeight {
                        Text(player.subtitle.uppercased())
                            .font(.custom(FontName.condBold, size: 12))
                            .foregroundStyle(team.onPrimary.opacity(0.72))
                    }
                }
                Spacer(minLength: 6)
                // Team logo (or country flag for teamless sports) during play; the grade (the
                // hidden sort number) replaces it on reveal — unless this is a vibes puzzle,
                // which never shows a number. On a full card the crest is already the watermark
                // behind all this, so the corner badge is only worth its width when it is the
                // grade.
                if isLocked && showGrade {
                    VStack {
                        gradeChip
                        if fillsHeight { Spacer(minLength: 0) }
                    }
                } else if !fillsHeight {
                    TeamLogoBadge(sport: sport, teamAbbr: player.teamAbbr, tint: team.onPrimary)
                }
            }
            if fillsHeight {
                Spacer(minLength: 8)
                chipStrip
            }
        }
        .padding(.horizontal, 14).padding(.vertical, fillsHeight ? 15 : 11)
    }

    /// What window of production this card represents, read off the row's own optional fields
    /// so the card doesn't need the puzzle passed in. The *wording* comes from `PuzzleGrain`
    /// rather than three string literals here — that enum is where the app's grain vocabulary
    /// (and its Spanish) already lives, and a second copy would drift from the badge the
    /// pre-game header shows for the same puzzle.
    private var grain: PuzzleGrain {
        if player.week != nil || player.gameDate != nil { return .singleGame }
        if player.firstYear != nil { return .career }
        return .season
    }

    /// The card's metadata, spread along the bottom of the band where there is real width for
    /// it, rather than squeezed into the ~170pt text column beside the photo. Segments are
    /// dropped when absent, so a traded row (deliberately blank `team_abbr`) loses the code
    /// chip instead of rendering an empty one.
    private var metaChips: [String] {
        var chips: [String] = []
        if !player.teamAbbr.isEmpty { chips.append(player.teamAbbr.uppercased()) }
        if let week = player.week, let opponent = player.opponent {
            chips.append("WK \(week) · \(opponent.uppercased())")
        } else if let date = player.gameDate, let opponent = player.opponent {
            chips.append("\(date.uppercased()) · \(opponent.uppercased())")
        }
        if let first = player.firstYear, let last = player.lastYear {
            chips.append(first == last ? "\(first)" : "\(first)–\(last)")
        } else {
            chips.append(String(player.seasonYear))
        }
        chips.append(grain.badgeLabel)
        return chips
    }

    private var chipStrip: some View {
        HStack(spacing: 6) {
            ForEach(metaChips, id: \.self) { chip in
                Text(chip)
                    .font(.custom(FontName.condBold, size: 11))
                    .foregroundStyle(team.onPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(team.onPrimary.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The PPR/fantasy point total (the hidden sort number), shown only on reveal.
    private var gradeChip: some View {
        VStack(spacing: 0) {
            Text(player.gradeText)
                .font(.hero(24))
                .lineLimit(1)
                .minimumScaleFactor(0.6)   // "4,713.8" (NBA season totals) must fit the chip
                .foregroundStyle(team.onSecondary)
            Text(gradeUnit)
                .font(.custom(FontName.condBold, size: 9))
                .foregroundStyle(team.onSecondary.opacity(0.8))
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(team.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Stats split into rows that are always *balanced*, so the last row is never one lone
    /// cell against two empty thirds.
    ///
    /// The old layout was a fixed 3-wide `LazyVGrid`, which meant the two most common card
    /// shapes in the catalog paid for columns they never filled: a 5-stat line (284 of the
    /// 400 bundled cards — every QB with a rushing line) rendered 3 + 1 orphan, and a 4-stat
    /// line (97 cards) rendered 3 + 1 orphan with two dead thirds under it. Balancing instead
    /// gives 5 → 3+2 and 4 → 2+2: same stats, no holes.
    private var statRows: [[PlayerSeason.StatLine]] {
        let stats = player.stats
        guard !stats.isEmpty else { return [] }
        let rowCount = Int(ceil(Double(stats.count) / 3.0))
        let base = stats.count / rowCount
        let remainder = stats.count % rowCount     // spread over the leading rows
        var rows: [[PlayerSeason.StatLine]] = []
        var i = 0
        for row in 0..<rowCount {
            let size = base + (row < remainder ? 1 : 0)
            rows.append(Array(stats[i..<(i + size)]))
            i += size
        }
        return rows
    }

    /// The stat line as a broadcast-style sheet: every number in its own tile with a team-color
    /// rule down its leading edge, rows sharing the card's vertical space equally. Tiles are what
    /// turn the leftover room into structure — the previous free-floating text on bare white
    /// read as a mostly-empty card no matter how much space it was given.
    private var statSheet: some View {
        VStack(spacing: 8) {
            ForEach(Array(statRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.label) { stat in statTile(stat) }
                }
                // Capped, not greedy: a tile is sized to its number. Above roughly this the
                // number starts floating in its own tile and the card reads empty again.
                .frame(maxHeight: fillsHeight ? 88 : nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, isLocked ? 4 : 2)
    }

    private func statTile(_ stat: PlayerSeason.StatLine) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(team.primary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(hideStats ? "—" : stat.value)
                    .font(.custom(FontName.condBlack, size: fillsHeight ? 24 : 20))
                    .foregroundStyle(hideStats ? Color.textMuted : Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(stat.label.uppercased())
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
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
            segment(title: String(localized: "Cut"), pile: .cut, gradient: Self.cutGradient)
            segment(title: String(localized: "Keep"), pile: .keep, gradient: Self.keepGradient)
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
                .font(.custom(active ? FontName.condBlack : FontName.condBold,
                              size: fillsHeight ? 17 : 15))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, fillsHeight ? 13 : 9)
                .background(gradient)
                .opacity(disabled ? 0.3 : (active || assignment == nil ? 1 : 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("\(title) \(player.name)")
        .accessibilityHint(disabled
                           ? "\(pile == .keep ? String(localized: "Keep") : String(localized: "Cut")) pile is full"
                           : "")
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
