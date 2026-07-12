import SwiftUI

struct DraftSpinResultView: View {
    let sport: Sport
    let picks: [CatalogSeason]
    let result: DraftSpinResult
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @State private var confetti = 0

    private var heroFill: Color { result.outcome == .champion ? .voltFill : .accentFill }
    private var heroInk: Color { result.outcome == .champion ? .onVolt : .onAccent }

    /// The single highest-power pick in the lineup — the "card of the round," highlighted
    /// with the holographic foil treatment as the one orchestrated sparkle (matches the
    /// Keep4 result screen's `topSeason` pattern).
    private var topPick: CatalogSeason? {
        picks.max { DraftSpinSimulator.power($0, sport: sport) < DraftSpinSimulator.power($1, sport: sport) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    if let top = topPick { topSeasonCard(top).heroReveal(1) }
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(2) }
                    lineupList.heroReveal(3)
                    shareCardPreview.heroReveal(4)
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: result.outcome == .champion ? 90 : 40)
        .onAppear { if result.outcome == .champion { confetti += 1 } }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(result.outcome.title(for: sport))
                .font(.heading)
                .foregroundStyle(heroInk.opacity(0.85))
            CountUpText(value: result.totalPoints, font: .heroNumber, color: heroInk)
            Text("\(result.wins)-\(result.losses) RECORD")
                .font(.label12)
                .foregroundStyle(heroInk.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: heroFill)
    }

    private func topSeasonCard(_ player: CatalogSeason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOP SEASON").font(.heading).foregroundStyle(Color.textPrimary)
            pickRow(player)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
                .foil(active: true, cornerRadius: 14)
        }
    }

    private var lineupList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR LINEUP").font(.heading).foregroundStyle(Color.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(picks.enumerated()), id: \.element.id) { i, player in
                    pickRow(player)
                    if i < picks.count - 1 { Rectangle().fill(Color.hairline).frame(height: Hairline.width) }
                }
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
        }
    }

    /// The reveal moment shows the player's FULL position-relevant line (explicit
    /// feedback: results must carry every stat that matters for the position, via the
    /// same shared grid every format uses).
    private func pickRow(_ player: CatalogSeason) -> some View {
        let team = TeamColors.palette(sport: sport, abbr: player.teamAbbr)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PlayerHeadshotBadge(headshot: player.headshot, tint: team.primary, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.name).font(.custom(FontName.condBold, size: 14)).foregroundStyle(Color.textPrimary)
                    Text("\(player.teamAbbr.uppercased()) · \(String(player.seasonYear))")
                        .font(.label11).foregroundStyle(Color.textMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int((DraftSpinSimulator.power(player, sport: sport) * 100).rounded()))")
                        .font(.custom(FontName.condBlack, size: 16)).foregroundStyle(Color.accentText)
                    Text("POWER").font(.label11).foregroundStyle(Color.textMuted)
                }
            }
            PositionStatGrid(sport: sport, position: player.position, stats: player.stats)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var shareCardPreview: some View {
        let card = DraftSpinShareCardView(sport: sport, picks: picks, result: result)
        return ShareLink(item: card.rendered(), preview: SharePreview("My Draft & Spin season", image: card.rendered())) {
            Label("SHARE RESULT", systemImage: "square.and.arrow.up").ctaLabel()
        }
        .buttonStyle(PrimePressStyle())
        .simultaneousGesture(TapGesture().onEnded {
            container.track(.shareTapped, ["surface": "draftspin_result"])
        })
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            Button(action: onDone) {
                Text("DONE").font(.heading).foregroundStyle(Color.accentText)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(Color.surface)
        }
    }
}

/// Shareable record card (M13 share-card pattern: Prime Time frame, ink border, hard ledge —
/// same shape as `ShareCardView`/`PuzzlePreviewCardView`, applied to a Draft & Spin season).
struct DraftSpinShareCardView: View {
    let sport: Sport
    let picks: [CatalogSeason]
    let result: DraftSpinResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Wordmark(size: 20)
                    Spacer()
                    Text("DRAFT & SPIN").font(.custom(FontName.condBlack, size: 14)).foregroundStyle(Color.onAccent.opacity(0.85))
                }
                Text(result.outcome.title(for: sport)).font(.custom(FontName.condBlack, size: 26)).foregroundStyle(Color.onAccent)
                Text("\(result.wins)-\(result.losses) · \(result.totalPoints) PTS")
                    .font(.custom(FontName.condBold, size: 15)).foregroundStyle(Color.onAccent.opacity(0.85))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentFill)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(picks) { player in
                    Text("\(player.name.uppercased()) · \(player.teamAbbr.uppercased())")
                        .font(.custom(FontName.condBold, size: 13))
                        .foregroundStyle(Color.textPrimary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface1)

            Text("PLAY AT PLAYBOOK")
                .font(.custom(FontName.condBold, size: 11))
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceMuted)
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2.5))
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color.borderInk).offset(x: 4, y: 4).padding(6))
    }

    @MainActor
    func rendered(scale: CGFloat = 3) -> Image {
        let renderer = ImageRenderer(content: self)
        renderer.scale = scale
        if let ui = renderer.uiImage { return Image(uiImage: ui) }
        return Image(systemName: "square.dashed")
    }
}
