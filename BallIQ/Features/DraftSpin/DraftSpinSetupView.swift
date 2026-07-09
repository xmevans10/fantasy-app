import SwiftUI

/// Draft & Spin's pre-game options, on the shared `GameSetupScreen` scaffold — sport pick
/// plus the reference app's config rows (Roster / Teams / Season variations), mapped onto
/// what the catalog can honestly support (see `DraftSpinSettings`). The Roster row only
/// appears for NFL and is locked to "Offense only": the catalog carries no defensive
/// players, and a control advertising data we don't have would be a lie.
struct DraftSpinSetupView: View {
    @Binding var sport: Sport
    @Binding var settings: DraftSpinSettings
    let onStart: () -> Void
    let onClose: () -> Void

    var body: some View {
        GameSetupScreen(formatName: "Draft & Spin",
                        title: "Set your draft rules",
                        startLabel: "Spin to draft",
                        sport: $sport,
                        onStart: onStart,
                        onClose: onClose)
        {
            if sport == .nfl {
                SetupOptionCard(
                    title: "ROSTER",
                    caption: "Defensive player data isn't in the catalog yet — offense it is.")
                {
                    SetupSegmentedControl(options: ["OFFENSE ONLY", "BOTH SIDES"],
                                          selectedIndex: 0, enabled: [true, false]) { _ in }
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
