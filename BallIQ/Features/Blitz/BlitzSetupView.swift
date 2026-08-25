import SwiftUI

/// Puzzle Blitz's pre-game options, on the shared `GameSetupScreen` scaffold: sports (the one
/// multi-select in the app — a blitz run legitimately spans them), run length, and which formats
/// may be drawn.
///
/// The caption under PUZZLE TYPES is the honest part. An all-formats five-minute run is about five
/// boards, because a K4C4 board is fifteen Over/Unders long (`BlitzConfig.estimatedBoards`), and a
/// player who wanted a fast-twitch blitz needs to learn that here rather than by watching the
/// clock die on their second sort.
struct BlitzSetupView: View {
    @Binding var config: BlitzConfig
    /// The primary sport `GameSetupScreen` tracks for its entitlement guard, app-wide default
    /// write, and identity warm. Owned by the host so it survives this view's redraws; kept in
    /// step with `config.sports` by the scaffold itself.
    @Binding var sport: Sport
    let onStart: () -> Void
    let onClose: () -> Void

    private let typeColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        GameSetupScreen(formatName: "Puzzle Blitz",
                        title: "Set your blitz",
                        startLabel: "Start the blitz",
                        sport: $sport,
                        onStart: onStart,
                        onClose: onClose,
                        sports: $config.sports)
        {
            SetupOptionCard(
                title: "TIMER",
                caption: "The clock decides how many puzzles you get — never how long you get on one. Time out mid-board and you still finish it; it's just your last.")
            {
                SetupSegmentedControl(
                    options: BlitzDuration.allCases.map { LocalizedStringKey($0.shortLabel) },
                    selectedIndex: BlitzDuration.allCases.firstIndex(of: config.duration) ?? 0)
                { index in
                    config.duration = BlitzDuration.allCases[index]
                }
            }

            SetupOptionCard(
                title: "PUZZLE TYPES",
                caption: typesCaption)
            {
                LazyVGrid(columns: typeColumns, spacing: 8) {
                    ForEach(BlitzFormat.allCases) { format in
                        typeChip(format)
                    }
                }
            }

            SetupOptionCard(
                title: "SCORING",
                caption: "No score until the clock stops. Every format pays the same per second at par, minus what a coin flip would have got you — so the mix you pick is taste, not strategy.")
            { EmptyView() }
        }
    }

    /// Names the format no chosen sport can serve, rather than leaving the player to notice it
    /// never comes up. One sentence, only when it applies — see `BlitzConfig.servableFormats`.
    private var typesCaption: LocalizedStringKey {
        let unservable = config.orderedFormats.filter { !$0.isAvailable(forAny: config.sports) }
        if let format = unservable.first {
            return "\(format.displayName) needs club careers, so it can't come up for \(unservableSportList). About \(config.estimatedBoards) puzzles from the rest."
        }
        return "About \(config.estimatedBoards) puzzles at this mix. Drop the long formats for a faster blitz."
    }

    /// The chosen sports that can't serve a club-career format, listed for the caption above.
    private var unservableSportList: String {
        let names = config.orderedSports.filter { !$0.hasClubCareers }.map(\.displayName)
        return ListFormatter.localizedString(byJoining: names)
    }

    private func typeChip(_ format: BlitzFormat) -> some View {
        let active = config.formats.contains(format)
        // Dimmed, not hidden, and still tickable: the format is fine, this *sport* can't serve it
        // (Journeyman + tennis). Hiding the chip would read as the app losing a feature; greying
        // it explains itself alongside the caption, and adding another sport brings it straight
        // back without the player having to re-tick anything.
        let servable = format.isAvailable(forAny: config.sports)
        return Button {
            Haptics.tap()
            withAnimation(Motion.snap) { toggle(format) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: !servable ? "slash.circle" : (active ? "checkmark" : format.symbol))
                    .font(.system(size: 11, weight: .bold))
                Text(format.displayName)
                    .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 13))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? format.onTint : Color.textPrimary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .background(active ? format.tint : Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(servable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityHint(servable ? "" :
            String(localized: "Not available for \(unservableSportList)"))
    }

    /// Refuses to untick the last format, for the same reason the sport picker refuses to empty
    /// its set: a config that can't serve a board would disable Start with nothing on screen
    /// explaining why.
    private func toggle(_ format: BlitzFormat) {
        if config.formats.contains(format) {
            // Counts SERVABLE formats, not ticked ones: with tennis selected, "Journeyman +
            // Who Am I?" is two ticks but only one playable format, and unticking Who Am I?
            // would leave a config that can't deal a single board.
            guard config.servableFormats.count > 1
                    || !format.isAvailable(forAny: config.sports) else { return }
            config.formats.remove(format)
        } else {
            config.formats.insert(format)
        }
    }
}
