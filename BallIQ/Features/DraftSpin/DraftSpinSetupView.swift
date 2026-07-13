import SwiftUI

/// Draft & Spin's pre-game options, on the shared `GameSetupScreen` scaffold — sport pick
/// plus the reference app's config rows (Roster / Teams / Season variations), mapped onto
/// what the catalog can honestly support (see `DraftSpinSettings`). The Roster row only
/// appears for NFL and is locked to "Offense only": the catalog carries no defensive
/// players, and a control advertising data we don't have would be a lie.
///
/// Backlog #4: a MODE row (Free Play / Today's Challenge) sits above the rest. `GameSetupScreen`
/// always renders its own SPORT grid regardless of mode, so "sport forced, not pickable" in
/// challenge mode is enforced via `lockableSport`'s no-op setter rather than by hiding that
/// grid — `GameSetupScreen` is a shared scaffold this view doesn't own.
struct DraftSpinSetupView: View {
    @Binding var sport: Sport
    @Binding var settings: DraftSpinSettings
    @Binding var isChallenge: Bool
    let onStart: () -> Void
    let onClose: () -> Void

    /// Passed to `GameSetupScreen` instead of `$sport` directly: in challenge mode its getter
    /// still reflects the live `sport` value (kept in sync with `sportOfTheDay` by the MODE
    /// row's own toggle below) but the setter swallows any tap on a different sport, so the
    /// picker renders normally yet can't actually change the forced sport.
    private var lockableSport: Binding<Sport> {
        Binding(get: { sport }, set: { newValue in if !isChallenge { sport = newValue } })
    }

    var body: some View {
        GameSetupScreen(formatName: "Draft & Spin",
                        title: "Set your draft rules",
                        startLabel: isChallenge ? "Start today's challenge" : "Spin to draft",
                        sport: lockableSport,
                        onStart: onStart,
                        onClose: onClose)
        {
            SetupOptionCard(
                title: "MODE",
                caption: isChallenge
                    ? "Same \(sport.displayName) rosters as every other player today. One scored run per day — replays after that only earn XP."
                    : "Fully random spins, any sport, anytime — practice or grind XP.")
            {
                SetupSegmentedControl(options: ["FREE PLAY", "TODAY'S CHALLENGE"],
                                      selectedIndex: isChallenge ? 1 : 0)
                { index in
                    isChallenge = index == 1
                    if isChallenge { sport = DraftSpinConstraint.sportOfTheDay(Date()) }
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
    }
}
