import SwiftUI

/// Draft & Spin: spin today's featured sport, then for each lineup slot — spin a real (team,
/// year), browse that real roster with full visible stats, and assign your pick to whichever
/// open slot their position fits. Spin again for the next slot until the lineup is full, then
/// reveal a simulated season (length varies by sport — see `DraftSpinSimulator.seasonShape(for:)`).
/// XP-only/unranked — the sim is luck-dominant by design, so it must never move the competitive
/// ladder (`RepositoryContainer.complete(ranked: false)`, same posture as community puzzles).
///
/// Backlog #4 adds a second mode alongside free play: Today's Challenge forces `sport` to
/// `sportOfTheDay` and re-seeds every spin from `challengeRoundGenerator` (day + round index)
/// instead of the system RNG, so every player sees the same round-by-round rosters. Free play
/// is untouched — same `SystemRandomNumberGenerator()` call as before this backlog item.
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
    @State private var showingSetup = true
    @State private var roundRosterReady = false
    @State private var settings = DraftSpinSettings.default
    /// One-team mode: the franchise locked by the first assigned pick, and the years
    /// already spun for it (each later round must land on a fresh year — see `spinRound`).
    @State private var lockedTeam: String?
    @State private var usedLockedYears: Set<Int> = []
    @State private var isChallenge = false
    /// Whether this challenge run became the day's official score (see
    /// `DraftSpinChallengeStore`) — false means an earlier run already locked one in today,
    /// so this run is XP-only practice and must not overwrite it.
    @State private var isOfficialChallengeRun = true
    private let challengeStore = DraftSpinChallengeStore()
    private var challengeDay: String { OverUnderRoundGenerator.dayString(Date()) }

    private var picks: [CatalogSeason] { slots.compactMap(\.pick) }
    private var openSlots: [DraftSpinLineupSlot] { slots.filter { $0.pick == nil } }
    /// Real team codes / years from this sport's own broad sample — feeds the spin reel so it
    /// only ever flashes options from the sport actually being played (see `SpinRevealView`).
    private var sampleTeamAbbrs: [String] { sample.map { $0.teamAbbr.uppercased() } }
    private var sampleYears: [String] { sample.map { String($0.seasonYear) } }
    /// Season variations OFF ("Prime only"): players already in the lineup can't reappear.
    private var excludedNames: Set<String> {
        settings.allowSeasonVariations ? [] : Set(picks.map(\.name))
    }

    var body: some View {
        Group {
            if let result {
                DraftSpinResultView(sport: sport, picks: picks, result: result, rewards: rewards,
                                    isChallenge: isChallenge, isOfficialChallengeRun: isOfficialChallengeRun,
                                    onDone: { dismiss() })
            } else if showingSetup {
                DraftSpinSetupView(sport: $sport, settings: $settings, isChallenge: $isChallenge,
                                   onStart: { Task { await startDraft() } },
                                   onClose: { dismiss() })
            } else if loading {
                loadingScreen
            } else if showingReveal, let round = currentRound {
                SpinRevealView(team: round.team, year: String(round.year),
                               roundLabel: "Round \(min(roundIndex + 1, slots.count)) of \(slots.count)",
                               realDecoyTeams: sampleTeamAbbrs, realDecoyYears: sampleYears,
                               rosterReady: $roundRosterReady) {
                    withAnimation(Motion.snap) { showingReveal = false }
                }
            } else {
                draftBoard
            }
        }
        .background(Color.appBackground)
        .task { await load() }
        .onChange(of: sport) { _, selectedSport in
            // Warm the broad discovery pool while the player is still choosing settings.
            // This changes no gameplay state—the eventual team/year remains a fresh random draw.
            if showingSetup { container.catalog.prefetchDraftSpinSample(for: selectedSport) }
        }
    }

    private func load() async {
        // Default the picker: debug override, else the last sport played anywhere in the
        // app, else this format's daily rotation. The setup screen owns the final choice.
        sport = DebugLaunch.draftSpinSport
            ?? container.sportFilter.sport
            ?? DraftSpinConstraint.sportOfTheDay(Date())
        loading = false
        if showingSetup { container.catalog.prefetchDraftSpinSample(for: sport) }
        // Screenshot flows target the board/result, not the setup screen — skip straight in
        // with default settings (except the flag that exists to capture setup itself).
        if DebugLaunch.autoOpenDraftSpin && !DebugLaunch.holdDraftSpinSetup {
            await startDraft()
        }
    }

    private func startDraft() async {
        // Defensive re-force: the setup screen's MODE toggle already snaps `sport` to
        // `sportOfTheDay` the moment challenge mode is switched on, but this covers the debug
        // -screenshotDraftSpin* flows, which skip the setup screen (and thus that toggle
        // handler) entirely — see `load()`.
        if isChallenge { sport = DraftSpinConstraint.sportOfTheDay(Date()) }
        isOfficialChallengeRun = isChallenge && !challengeStore.hasCompletedChallenge(for: challengeDay)
        showingSetup = false
        loading = true
        slots = DraftSpinConstraint.lineupSlots(for: sport)
        // A broad sample — only used to *discover* a good (team, year) each round; the round's
        // complete roster is re-fetched separately once a combo is chosen (see spinNextRound).
        let sampleStartedAt = Date()
        sample = await container.catalog.draftSpinSample(for: sport)
        let sampleLoadMilliseconds = Int(Date().timeIntervalSince(sampleStartedAt) * 1_000)
        container.track(.gameStarted, [
            "format": "draftspin", "sport": sport.rawValue,
            "one_team": String(settings.lockToOneTeam),
            "season_variations": String(settings.allowSeasonVariations),
            "sample_load_ms": String(sampleLoadMilliseconds),
            "challenge": String(isChallenge),
        ])
        loading = false
        await spinNextRound()
    }

    private func spinNextRound() async {
        expandedPlayerID = nil
        rerollUsedThisRound = false
        let spin: (team: String, year: Int)?
        if isChallenge {
            // Same seed for everyone on the same day — see `challengeRoundGenerator`'s doc
            // comment for the (accepted) determinism caveat once picks diverge.
            var rng = DraftSpinConstraint.challengeRoundGenerator(sport: sport, date: Date(), roundIndex: roundIndex)
            spin = DraftSpinConstraint.spinRound(
                from: sample, sport: sport, openRoles: openSlots.map(\.role),
                lockedTeam: lockedTeam, usedLockedYears: usedLockedYears,
                excludeNames: excludedNames, using: &rng)
        } else {
            var rng = SystemRandomNumberGenerator()   // every spin is genuinely random
            spin = DraftSpinConstraint.spinRound(
                from: sample, sport: sport, openRoles: openSlots.map(\.role),
                lockedTeam: lockedTeam, usedLockedYears: usedLockedYears,
                excludeNames: excludedNames, league: settings.soccerLeague, using: &rng)
        }
        guard let (team, year) = spin else {
            finish()
            return
        }
        await loadRoundRoster(team: team, year: year)
    }

    private func reroll() async {
        // No reroll in Today's Challenge: the whole point is every player facing the same
        // spin, and a free reroll would let players fish for a better one it wouldn't share.
        guard !rerollUsedThisRound, !isChallenge else { return }
        rerollUsedThisRound = true
        var rng = SystemRandomNumberGenerator()
        guard let (team, year) = DraftSpinConstraint.spinRound(
            from: sample, sport: sport, openRoles: openSlots.map(\.role),
            lockedTeam: lockedTeam, usedLockedYears: usedLockedYears,
            excludeNames: excludedNames, league: settings.soccerLeague, using: &rng
        ) else { return }
        await loadRoundRoster(team: team, year: year)
    }

    /// The sample that picked (team, year) is only broad enough for discovery, not guaranteed to
    /// carry that combo's complete roster (the same sample-vs-complete gap the earlier
    /// single-spin design hit) — re-fetch the real thing before showing it.
    private func loadRoundRoster(team: String, year: Int) async {
        // Start the reveal as soon as the random team/year is known. The reel gives the exact,
        // narrow roster request time to complete instead of making the player stare at a spinner.
        currentRound = DraftSpinRound(team: team, year: year, roster: [])
        expandedPlayerID = nil
        roundRosterReady = false
        showingReveal = true

        let fetched = await container.catalog.draftSpinRoster(sport: sport, team: team, year: year)
        // Excluded names (season variations OFF) are dropped from display too — `spinRound`
        // already guaranteed at least one placeable candidate survives this filter.
        let roster = fetched.filter { $0.teamAbbr == team && !excludedNames.contains($0.name) }
        currentRound = DraftSpinRound(team: team, year: year, roster: roster)
        roundRosterReady = true
        if DebugLaunch.autoSubmitDraftSpin { autoPickForScreenshot(roster) }
    }

    private var loadingScreen: some View {
        VStack(spacing: 18) {
            Text("DRAFT & SPIN").font(.label12).kerning(2).foregroundStyle(Color.accentText)
            Text("OPENING THE VAULT")
                .font(.custom(FontName.condBlack, size: 32))
                .foregroundStyle(Color.textPrimary)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voltFill)
                        .frame(width: 14, height: 14)
                }
            }
            .shadow(color: Color.voltFill.opacity(0.7), radius: 7)
            Text("Finding real \(sport.displayName) rosters…")
                .font(.body14).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
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
            Text(isChallenge ? "TODAY'S CHALLENGE" : "DRAFT & SPIN")
                .font(.label12).foregroundStyle(Color.accentText)
            Text("Build your \(sport.displayName) squad").font(.title).foregroundStyle(Color.textPrimary)
            if let round = currentRound {
                HStack(spacing: 10) {
                    chip(label: "TEAM", value: round.team.uppercased(), tint: .accentFill)
                    chip(label: "YEAR", value: String(round.year), tint: .successFill)
                    Spacer()
                    if isChallenge {
                        // No reroll here — see `reroll()`'s doc comment (a free reroll would
                        // undercut "everyone sees the same spin").
                        Text("SAME FOR EVERYONE").font(.label11).foregroundStyle(Color.textMuted)
                    } else {
                        Button {
                            Task { await reroll() }
                        } label: {
                            Text("Reroll (\(rerollUsedThisRound ? 0 : 1))")
                                .font(.custom(FontName.condBold, size: 13))
                                .foregroundStyle(rerollUsedThisRound ? Color.textMuted : Color.accentText)
                        }
                        .disabled(rerollUsedThisRound)
                    }
                }
                if let expandedPlayerID, let player = round.roster.first(where: { $0.id == expandedPlayerID }) {
                    Text("PLACE \(player.name.uppercased()) IN A HIGHLIGHTED SLOT.")
                        .font(.label11).foregroundStyle(Color.accentText)
                } else {
                    Text("TAP A PLAYER FOR THEIR FULL STAT LINE.")
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
                    PositionStatGrid(sport: sport, position: player.position, stats: player.stats)
                    if eligible.isEmpty {
                        Text("No open slot fits this position.").font(.label11).foregroundStyle(Color.dangerText)
                    } else {
                        Text("CHOOSE A HIGHLIGHTED LINEUP SLOT BELOW")
                            .font(.label11).foregroundStyle(Color.accentText)
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

        return VStack(spacing: 0) {
            if expandedPlayer != nil {
                Text("PLACE PLAYER")
                    .font(.label11).foregroundStyle(Color.accentText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
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
        }
        .background(Color.surface)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: Hairline.width) }
    }

    // MARK: - Logic

    private func assign(_ player: CatalogSeason, to slot: DraftSpinLineupSlot) {
        Haptics.tap()
        guard let index = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[index].pick = player
        // One-team mode: the first assigned pick locks the franchise (so a round-1 reroll
        // still changes it), and each locked round's year is burned for the rest of the draft.
        if settings.lockToOneTeam, let round = currentRound {
            if lockedTeam == nil { lockedTeam = round.team }
            if round.team == lockedTeam { usedLockedYears.insert(round.year) }
        }
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
        var rng = SystemRandomNumberGenerator()
        let simulated = DraftSpinSimulator.simulate(lineup: picks, sport: sport, using: &rng)
        let dailyID = "draftspin-\(sport.rawValue)-\(OverUnderRoundGenerator.dayString(Date()))"
        let performance: Double
        switch simulated.outcome {
        case .champion: performance = 1.0
        case .madePlayoffs: performance = 0.6
        case .missedPlayoffs: performance = 0.3
        }
        // Only the day's FIRST challenge completion becomes official; `recordIfFirst`'s own
        // return value is authoritative (re-derived here rather than trusting the guess made
        // when the run started, in case the day flips over a UTC midnight mid-session).
        if isChallenge {
            isOfficialChallengeRun = challengeStore.recordIfFirst(sport: sport, result: simulated, day: challengeDay)
        }
        Task {
            // XP-only/unranked by design (see type doc comment) — `ranked: false` always, since
            // the luck-dominant sim result must never move the competitive ladder. This holds
            // for every challenge replay too: a challenge run only ever gates the *separate*
            // `DraftSpinChallengeStore` score, never the rating ladder.
            rewards = await container.complete(format: .draftSpin, sport: sport, performance: performance,
                                               perfect: simulated.outcome == .champion,
                                               puzzleID: dailyID, ranked: false)
            withAnimation(Motion.snap) { result = simulated }
        }
    }
}
