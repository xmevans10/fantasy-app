import SwiftUI

/// Draft & Spin's pre-game options, on the shared `GameSetupScreen` scaffold — sport pick
/// plus the reference app's config rows (Roster / Teams / Season variations), mapped onto
/// what the catalog can honestly support (see `DraftSpinSettings`). The Roster row only
/// appears for NFL and is locked to "Offense only": the catalog carries no defensive
/// players, and a control advertising data we don't have would be a lie.
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

    /// The competition name for the chosen league value (falls back to the raw value if it's
    /// somehow not in the curated list) — used in the caption so it reads "restricted to
    /// Premier League", not the underlying "England" country tag.
    private var selectedLeagueName: String {
        guard let value = settings.soccerLeague else { return "" }
        return DraftSpinConstraint.majorSoccerLeagues.first { $0.value == value }?.name ?? value
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
                        onClose: onClose)
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
                    ForEach(DraftSpinConstraint.lineupSlots(for: sport)) { slot in
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

            if sport == .nfl {
                SetupOptionCard(
                    title: "ROSTER",
                    caption: "Defensive player data isn't in the catalog yet — offense it is.")
                {
                    Text("OFFENSE ONLY")
                        .font(.custom(FontName.condBlack, size: 13))
                        .foregroundStyle(Color.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentFill)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }

            // Daily Draft forces the shared daily seed — a personal league filter would let
            // players diverge from "everyone sees the same rosters," so this only shows in
            // Free Play (Daily Draft spins never read `settings.soccerLeague`).
            if sport == .soccer && !isDailyDraft {
                SetupOptionCard(
                    title: "LEAGUE",
                    caption: settings.soccerLeague == nil
                        ? "Spins draw from any of the ~38 countries' top flights we track."
                        : "Spins are restricted to \(selectedLeagueName) — if a round can't fill an open slot from just that league, it falls back to any league rather than getting stuck.")
                {
                    LeagueChipPicker(selected: $settings.soccerLeague)
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
private struct LeagueChipPicker: View {
    @Binding var selected: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 2)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            chip(label: String(localized: "ALL LEAGUES"), active: selected == nil) { selected = nil }
            // Chip shows the competition name; the filter still matches on `league.value`
            // (the country label the catalog is tagged by) — see `SoccerLeague`'s doc comment.
            ForEach(DraftSpinConstraint.majorSoccerLeagues, id: \.self) { league in
                chip(label: league.name.uppercased(), active: selected == league.value) {
                    selected = league.value
                }
            }
        }
    }

    private func chip(label: String, active: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 13))
                .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(active ? Color.accentFill : Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
