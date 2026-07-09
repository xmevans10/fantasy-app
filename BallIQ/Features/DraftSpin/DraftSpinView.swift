import SwiftUI

/// Draft & Spin: spin today's featured sport, then for each lineup slot — spin a real (team,
/// year), browse that real roster with full visible stats, and assign your pick to whichever
/// open slot their position fits. Spin again for the next slot until the lineup is full, then
/// reveal a simulated season (length varies by sport — see `DraftSpinSimulator.seasonShape(for:)`).
/// XP-only/unranked — the sim is luck-dominant by design, so it must never move the competitive
/// ladder (`RepositoryContainer.complete(ranked: false)`, same posture as community puzzles).
struct DraftSpinView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var sport: Sport = .nfl
    @State private var sample: [CatalogSeason] = []
    @State private var slots: [DraftSpinLineupSlot] = []
    @State private var roundIndex = 0
    @State private var rerollUsedThisRound = false
    @State private var currentRound: DraftSpinRound?
    @State private var expandedPlayerID: String?
    @State private var showingReveal = false
    @State private var result: DraftSpinResult?
    @State private var rewards: RepositoryContainer.SessionRewards?
    @State private var loading = true

    private var picks: [CatalogSeason] { slots.compactMap(\.pick) }
    private var openSlots: [DraftSpinLineupSlot] { slots.filter { $0.pick == nil } }

    var body: some View {
        Group {
            if let result {
                DraftSpinResultView(sport: sport, picks: picks, result: result, rewards: rewards,
                                    onDone: { dismiss() })
            } else if loading {
                ProgressView().tint(Color.accentText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showingReveal, let round = currentRound {
                SpinRevealView(team: round.team, year: String(round.year)) {
                    withAnimation(Motion.snap) { showingReveal = false }
                }
            } else {
                draftBoard
            }
        }
        .background(Color.appBackground)
        .task { await load() }
    }

    private func load() async {
        sport = DebugLaunch.draftSpinSport ?? DraftSpinConstraint.sportOfTheDay(Date())
        slots = DraftSpinConstraint.lineupSlots(for: sport)
        // A broad sample — only used to *discover* a good (team, year) each round; the round's
        // complete roster is re-fetched separately once a combo is chosen (see spinNextRound).
        sample = await container.catalog.search(CatalogQuery(sport: sport), limit: 2000)
        container.track(.gameStarted, ["format": "draftspin", "sport": sport.rawValue])
        loading = false
        await spinNextRound()
    }

    private func spinNextRound() async {
        expandedPlayerID = nil
        rerollUsedThisRound = false
        let openRoles = openSlots.map(\.role)
        guard let (team, year) = DraftSpinConstraint.spinRound(
            from: sample, sport: sport, date: Date(), roundIndex: roundIndex, reroll: 0, openRoles: openRoles
        ) else {
            finish()
            return
        }
        await loadRoundRoster(team: team, year: year)
    }

    private func reroll() async {
        guard !rerollUsedThisRound else { return }
        rerollUsedThisRound = true
        let openRoles = openSlots.map(\.role)
        guard let (team, year) = DraftSpinConstraint.spinRound(
            from: sample, sport: sport, date: Date(), roundIndex: roundIndex, reroll: 1, openRoles: openRoles
        ) else { return }
        await loadRoundRoster(team: team, year: year)
    }

    /// The sample that picked (team, year) is only broad enough for discovery, not guaranteed to
    /// carry that combo's complete roster (the same sample-vs-complete gap the earlier
    /// single-spin design hit) — re-fetch the real thing before showing it.
    private func loadRoundRoster(team: String, year: Int) async {
        let fetched = await container.catalog.search(
            CatalogQuery(sport: sport, minYear: year, maxYear: year), limit: 1000)
        let roster = fetched.filter { $0.teamAbbr == team }
        currentRound = DraftSpinRound(team: team, year: year, roster: roster)
        expandedPlayerID = nil
        showingReveal = true
        if DebugLaunch.autoSubmitDraftSpin { autoPickForScreenshot(roster) }
    }

    /// `-screenshotDraftSpinResult`: simctl can't tap through the roster/lineup UI, so pick the
    /// first roster player with an eligible open slot and assign them, letting `assign` chain
    /// into the next round automatically until the lineup is full.
    private func autoPickForScreenshot(_ roster: [CatalogSeason]) {
        for player in roster {
            let eligible = DraftSpinConstraint.eligibleSlots(for: player.position, in: openSlots, sport: sport)
            if let slot = eligible.first {
                assign(player, to: slot)
                return
            }
        }
    }

    // MARK: - Draft phase

    private var draftBoard: some View {
        VStack(spacing: 0) {
            header
            if let round = currentRound {
                rosterList(round)
            }
            lineupBar
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("Close")
                Spacer()
                Text("ROUND \(min(roundIndex + 1, slots.count)) OF \(slots.count)")
                    .font(.label12).foregroundStyle(Color.textMuted)
            }
            Text("DRAFT & SPIN").font(.label12).foregroundStyle(Color.accentText)
            Text("Today's sport: \(sport.displayName)").font(.title).foregroundStyle(Color.textPrimary)
            if let round = currentRound {
                HStack(spacing: 10) {
                    chip(label: "TEAM", value: round.team.uppercased(), tint: .accentFill)
                    chip(label: "YEAR", value: String(round.year), tint: .successFill)
                    Spacer()
                    Button {
                        Task { await reroll() }
                    } label: {
                        Text("Reroll (\(rerollUsedThisRound ? 0 : 1))")
                            .font(.custom(FontName.condBold, size: 13))
                            .foregroundStyle(rerollUsedThisRound ? Color.textMuted : Color.accentText)
                    }
                    .disabled(rerollUsedThisRound)
                }
                if let expandedPlayerID, let player = round.roster.first(where: { $0.id == expandedPlayerID }) {
                    Text("Tap a highlighted slot to place \(player.name).")
                        .font(.label11).foregroundStyle(Color.accentText)
                } else {
                    Text("Select a player, then tap a highlighted slot.")
                        .font(.label11).foregroundStyle(Color.textMuted)
                }
            }
        }
        .padding(16)
        .background(Color.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: Hairline.width) }
    }

    private func chip(label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            Text(value).font(.custom(FontName.condBlack, size: 16)).foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint, lineWidth: 2))
    }

    /// Every real position present in this round's roster, "All" first, in the sport's own
    /// formation-role order (matching the reference's QB/RB/WR/TE tab order) then alphabetical
    /// for anything else.
    private func positionTabs(_ round: DraftSpinRound) -> [String] {
        let formationOrder = (DraftSpinConstraint.formations[sport] ?? []).map(\.role)
        let present = Set(round.roster.map(\.position))
        let ordered = formationOrder.filter { present.contains($0) }
        let extra = present.subtracting(ordered).sorted()
        return ["All"] + ordered + extra
    }

    @State private var selectedTab = "All"

    private func rosterList(_ round: DraftSpinRound) -> some View {
        let tabs = positionTabs(round)
        let filtered = selectedTab == "All" ? round.roster : round.roster.filter { $0.position == selectedTab }
        let grouped = Dictionary(grouping: filtered, by: \.position)
        let sections = grouped.keys.sorted { a, b in
            let order = (DraftSpinConstraint.formations[sport] ?? []).map(\.role)
            let ai = order.firstIndex(of: a) ?? Int.max
            let bi = order.firstIndex(of: b) ?? Int.max
            return ai == bi ? a < b : ai < bi
        }

        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs, id: \.self) { tab in
                        let active = selectedTab == tab
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.uppercased())
                                .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 13))
                                .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(active ? Color.accentFill : Color.surfaceMuted)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if round.roster.isEmpty {
                Text("No players match.").font(.body14).foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections, id: \.self) { position in
                            Text("\(position.uppercased()) · \(grouped[position]?.count ?? 0)")
                                .font(.label11).foregroundStyle(Color.accentText)
                                .padding(.horizontal, 16)
                            ForEach(grouped[position] ?? []) { player in
                                playerRow(player)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playerRow(_ player: CatalogSeason) -> some View {
        let team = TeamColors.palette(sport: sport, abbr: player.teamAbbr)
        let expanded = expandedPlayerID == player.id
        let columns = ScoringStat.displayColumns(sport: sport, position: player.position)
        let extraStats = sport.sliceForPosition(ScoringStat.catalog(for: sport), position: player.position,
                                                minimum: 0, statKey: \.key)
        let eligible = expanded
            ? DraftSpinConstraint.eligibleSlots(for: player.position, in: openSlots, sport: sport) : []

        return Button {
            withAnimation(Motion.snap) { expandedPlayerID = expanded ? nil : player.id }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    PlayerHeadshotBadge(headshot: player.headshot, tint: team.primary, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.name).font(.custom(FontName.condBlack, size: 16)).foregroundStyle(Color.textPrimary)
                        Text("\(player.teamAbbr.uppercased()) · \(String(player.seasonYear))")
                            .font(.label11).foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                    ForEach(columns.prefix(2)) { stat in
                        if let value = player.stats[stat.key] {
                            VStack(spacing: 0) {
                                Text(stat.format(value)).font(.custom(FontName.condBlack, size: 15)).foregroundStyle(Color.textPrimary)
                                Text(stat.label.uppercased()).font(.label11).foregroundStyle(Color.textMuted)
                            }
                        }
                    }
                }
                if expanded {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(extraStats) { stat in
                            if let value = player.stats[stat.key] {
                                VStack(spacing: 0) {
                                    Text(stat.format(value)).font(.custom(FontName.condBlack, size: 14)).foregroundStyle(Color.textPrimary)
                                    Text(stat.label.uppercased()).font(.label11).foregroundStyle(Color.textMuted)
                                }
                            }
                        }
                    }
                    if eligible.isEmpty {
                        Text("No open slot fits this position.").font(.label11).foregroundStyle(Color.dangerText)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(expanded ? Color.accentFill : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var lineupBar: some View {
        let expandedPlayer = currentRound?.roster.first { $0.id == expandedPlayerID }
        let eligible = expandedPlayer.map {
            Set(DraftSpinConstraint.eligibleSlots(for: $0.position, in: openSlots, sport: sport).map(\.id))
        } ?? []

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(slots) { slot in
                    let highlighted = eligible.contains(slot.id)
                    Button {
                        guard highlighted, let player = expandedPlayer else { return }
                        assign(player, to: slot)
                    } label: {
                        VStack(spacing: 2) {
                            Text(slot.role.uppercased()).font(.label11).foregroundStyle(
                                highlighted ? Color.onAccent : (slot.pick != nil ? Color.textMuted : Color.textPrimary))
                            Text(slot.pick?.name.split(separator: " ").last.map(String.init) ?? "—")
                                .font(.custom(FontName.condBold, size: 13))
                                .foregroundStyle(highlighted ? Color.onAccent : Color.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(minWidth: 64)
                        .background(highlighted ? Color.accentFill : Color.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!highlighted)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color.surface)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: Hairline.width) }
    }

    // MARK: - Logic

    private func assign(_ player: CatalogSeason, to slot: DraftSpinLineupSlot) {
        Haptics.tap()
        guard let index = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[index].pick = player
        expandedPlayerID = nil
        currentRound = nil
        if openSlots.isEmpty {
            finish()
        } else {
            roundIndex += 1
            Task { await spinNextRound() }
        }
    }

    private func finish() {
        let simulated = DraftSpinSimulator.simulate(lineup: picks, sport: sport, date: Date())
        let dailyID = "draftspin-\(sport.rawValue)-\(OverUnderRoundGenerator.dayString(Date()))"
        let performance: Double
        switch simulated.outcome {
        case .champion: performance = 1.0
        case .madePlayoffs: performance = 0.6
        case .missedPlayoffs: performance = 0.3
        }
        Task {
            // XP-only/unranked by design (see type doc comment) — `ranked: false` always, since
            // the luck-dominant sim result must never move the competitive ladder.
            rewards = await container.complete(format: .draftSpin, sport: sport, performance: performance,
                                               perfect: simulated.outcome == .champion,
                                               puzzleID: dailyID, ranked: false)
            withAnimation(Motion.snap) { result = simulated }
        }
    }
}
