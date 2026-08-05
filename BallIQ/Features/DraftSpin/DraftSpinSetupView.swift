import SwiftUI

/// Draft & Spin's pre-game options, on the shared `GameSetupScreen` scaffold — sport pick
/// plus the reference app's config rows (Roster / Teams / Season variations), mapped onto
/// what the catalog can honestly support (see `DraftSpinSettings`). The Roster row appears
/// for NFL in Free Play and defaults to "Offense only" — Both sides (the six offense slots
/// plus DL/LB/DB) is opt-in now that the catalog carries real defensive players with IDP
/// stats; Daily Draft hides the row entirely so every player faces the same shared spins
/// (and thus always the offense-only default).
///
/// Backlog #4: a MODE row (Free Play / Daily Draft) sits above the rest. `GameSetupScreen`
/// always renders its own SPORT grid regardless of mode, so "sport forced, not pickable" in
/// Daily Draft mode is enforced via `lockableSport`'s no-op setter rather than by hiding that
/// grid — `GameSetupScreen` is a shared scaffold this view doesn't own.
struct DraftSpinSetupView: View {
    @Binding var sport: Sport
    @Binding var settings: DraftSpinSettings
    @Binding var isDailyDraft: Bool
    let onStart: () -> Void
    let onClose: () -> Void

    @State private var showingHowItWorks = false

    /// What the caption names the current selection — the same string the picker button shows,
    /// so the two can't disagree. Reads the deepest chosen level, meaning it says "2. Bundesliga"
    /// (or a club) where it used to only ever be able to say the nation.
    private var selectedLeagueName: String {
        settings.clubFilter.displayName(sport: .soccer)
    }

    /// Competitions the catalog actually holds clubs for. Everything else is listed but not
    /// selectable — filtering to a competition with no players would spin against an empty pool.
    private var playableSoccerLeagues: Set<String> {
        let live = TeamIdentityIndex.shared.leaguesWithTeams(sport: .soccer)
        // Before identity warms (cold launch/offline) fall back to the curated majors rather
        // than showing every row disabled.
        return live.isEmpty ? Set(DraftSpinConstraint.majorSoccerLeagues.map(\.value)) : live
    }

    /// Passed to `GameSetupScreen` instead of `$sport` directly: in Daily Draft mode its getter
    /// still reflects the live `sport` value (kept in sync with `sportOfTheDay` by the MODE
    /// row's own toggle below) but the setter swallows any tap on a different sport, so the
    /// picker renders normally yet can't actually change the forced sport.
    private var lockableSport: Binding<Sport> {
        Binding(get: { sport }, set: { newValue in if !isDailyDraft { sport = newValue } })
    }

    var body: some View {
        GameSetupScreen(formatName: "Draft & Spin",
                        title: "Set your draft rules",
                        startLabel: isDailyDraft ? "Start the Daily Draft" : "Spin to draft",
                        sport: lockableSport,
                        onStart: onStart,
                        onClose: onClose,
                        sportGateExempt: isDailyDraft)
        {
            SetupOptionCard(
                title: "MODE",
                caption: isDailyDraft
                    ? "Same \(sport.displayName) spins as every other player today. One official run per day — replays after that only earn XP."
                    : "Fully random spins, any sport, anytime — practice or grind XP.")
            {
                SetupSegmentedControl(options: ["FREE PLAY", "DAILY DRAFT"],
                                      selectedIndex: isDailyDraft ? 1 : 0)
                { index in
                    isDailyDraft = index == 1
                    if isDailyDraft { sport = DraftSpinConstraint.sportOfTheDay(Date()) }
                }
                if isDailyDraft {
                    Button {
                        Haptics.tap()
                        showingHowItWorks = true
                    } label: {
                        Label("How it works", systemImage: "info.circle")
                            .font(.label12)
                            .foregroundStyle(Color.accentText)
                    }
                    .buttonStyle(.plain)
                }
            }

            SetupOptionCard(
                title: "YOUR SQUAD",
                caption: "Every spin lands on a real team-season roster. Draft the best player for each open spot.")
            {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(DraftSpinConstraint.lineupSlots(for: sport, includeDefense: settings.includeDefense)) { slot in
                        Text(slot.role.uppercased())
                            .font(.custom(FontName.condBlack, size: 13))
                            .foregroundStyle(Color.accentText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            // Hidden in Daily Draft, same as LEAGUE: a roster choice would let players diverge
            // from the shared daily spins, so the daily path always uses the offense-only
            // default (`DraftSpinSettings.includeDefense` starts false and nothing in Daily
            // Draft mode writes to it).
            if sport == .nfl && !isDailyDraft {
                SetupOptionCard(
                    title: "ROSTER",
                    caption: settings.includeDefense
                        ? "Both sides: the six offense slots plus DL, LB and DB — real IDP stats (tackles, sacks, interceptions…)."
                        : "Offense only — the default. Switch to Both sides to draft real defenders too.")
                {
                    SetupSegmentedControl(options: ["OFFENSE ONLY", "BOTH SIDES"],
                                          selectedIndex: settings.includeDefense ? 1 : 0)
                    { settings.includeDefense = $0 == 1 }
                }
            }

            // Daily Draft forces the shared daily seed — a personal league filter would let
            // players diverge from "everyone sees the same rosters," so this only shows in
            // Free Play (Daily Draft spins never read `settings.soccerLeague`).
            if sport == .soccer && !isDailyDraft {
                SetupOptionCard(
                    title: "LEAGUE",
                    caption: settings.clubFilter.isAll
                        ? "Spins draw from every nation, division and club we track."
                        : "Spins are restricted to \(selectedLeagueName) — if a round can't fill an open slot from just that, it falls back to any league rather than getting stuck.")
                {
                    LeaguePickerButton(filter: $settings.clubFilter, sport: .soccer,
                                       playableNations: playableSoccerLeagues,
                                       league: $settings.soccerLeague)
                }
            }

            SetupOptionCard(
                title: "TEAMS",
                caption: settings.lockToOneTeam
                    ? "Round 1 spins a franchise, then every round spins a different year of that same team."
                    : "Every round spins any team and year.")
            {
                SetupSegmentedControl(options: ["ALL TEAMS", "ONE TEAM"],
                                      selectedIndex: settings.lockToOneTeam ? 1 : 0)
                { settings.lockToOneTeam = $0 == 1 }
            }

            SetupOptionCard(
                title: "SEASON VARIATIONS",
                caption: settings.allowSeasonVariations
                    ? "A player you drafted can show up again in a later round as a different season of themselves."
                    : "Each real player appears in your draft at most once.")
            {
                SetupSegmentedControl(options: ["ON", "PRIME ONLY"],
                                      selectedIndex: settings.allowSeasonVariations ? 0 : 1)
                { settings.allowSeasonVariations = $0 == 0 }
            }
        }
        .onAppear {
            // `-screenshotDraftSpinSetup -screenshotDailyDraftInfo`: simctl can't tap the info
            // button, so force the sheet open, already expanded for full capture.
            if DebugLaunch.autoOpenDailyDraftInfo { showingHowItWorks = true }
        }
        .sheet(isPresented: $showingHowItWorks) {
            HowItWorksSheet(
                title: "Daily Draft",
                intro: "Draft & Spin's daily competitive mode — one sport, one shot, everyone drafting from the same spins.",
                symbol: "dice.fill",
                tint: .accentText,
                tintBackground: .accentBg,
                rules: [
                    HowItWorksSheet.Rule(symbol: "calendar", title: "One sport a day",
                                         detail: "Daily Draft always plays today's featured sport — no picking your own."),
                    HowItWorksSheet.Rule(symbol: "person.3.fill", title: "Same spins, no rerolls",
                                         detail: "Every player gets the identical round-by-round spins today, and the reroll option is off."),
                    HowItWorksSheet.Rule(symbol: "checkmark.seal.fill", title: "First run is official",
                                         detail: "Your first completed run of the day is your official score. Replays after that only earn XP."),
                ],
                footnote: "Everyone's spins start identical; your draft picks steer which rosters you see next.",
                startExpanded: DebugLaunch.autoOpenDailyDraftInfo)
        }
    }
}

/// A wrapping chip row for a choice with more options than `SetupSegmentedControl` comfortably
/// fits (LEAGUE: "ALL LEAGUES" + `DraftSpinConstraint.majorSoccerLeagues`, 11 total) — same
/// capsule-chip visual language as the in-draft position tabs (`DraftSpinView.rosterList`).
/// Compact "current value, tap to change" control that opens `LeaguePicker` — the iOS pattern for
/// a field whose option list is too long to inline. Replaced a 2-column grid of 10 hardcoded
/// chips, which could not scale to the 44 competitions league identity now covers.
private struct LeaguePickerButton: View {
    @Binding var filter: ClubFilter
    let sport: Sport
    let playableNations: Set<String>
    /// Legacy flat league value, kept in sync with `filter.nation` so the setup screen's caption
    /// and any stored settings keep working. The spin itself now filters on the whole
    /// `ClubFilter` — see `DraftSpinConstraint.spinRound`.
    @Binding var league: String?
    @State private var showingPicker = false

    private var label: String { filter.displayName(sport: sport) }

    private var crest: URL? {
        if let club = filter.club {
            return TeamIdentityIndex.shared.identity(sport: sport, abbr: club,
                                                     league: filter.nation)?.logoURL
        }
        guard let nation = filter.nation else { return nil }
        return TeamIdentityIndex.shared.leagues(sport: sport, nation: nation).first?.logoURL
    }

    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 10) {
                if let crest {
                    RemoteImage(url: crest, targetSize: CGSize(width: 22, height: 22))
                        .frame(width: 22, height: 22)
                }
                Text(label.uppercased())
                    .font(.custom(FontName.condBlack, size: 14))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPicker) {
            NationLeagueClubPicker(filter: $filter, sport: sport,
                                   playableNations: playableNations)
        }
        .onChange(of: filter) { _, new in league = new.nation }
        .onAppear {
            // simctl can neither scroll this row into view nor tap it.
            if DebugLaunch.autoOpenLeaguePicker { showingPicker = true }
        }
    }
}
