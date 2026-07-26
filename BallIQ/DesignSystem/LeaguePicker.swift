import SwiftUI

/// Nation-grouped, searchable competition picker — the FIFA-style Nation → League → Club
/// hierarchy's middle step, rendered the way iOS renders long pickable lists (a sheet with a
/// pinned search field and sectioned rows, like Settings → Language & Region).
///
/// Replaces a flat 2-column grid of 10 hardcoded chips. That shape was fine for "the big five
/// plus a few", but league identity now covers 44 competitions across 37 nations including
/// second and third tiers, and a flat grid of 44 chips is unusable.
///
/// **Only competitions with playable data are selectable.** Lower divisions exist in the
/// `leagues` catalog before any club sweep has landed for them, and filtering the arcade to a
/// competition with no player-seasons would spin forever on an empty pool — so those rows render
/// disabled with a "SOON" tag rather than lying about what the filter can do.
struct LeaguePicker: View {
    /// The `CatalogSeason.league` value to filter by (a nation label) — nil = every league.
    @Binding var selection: String?
    let sport: Sport
    /// League values the catalog actually holds rows for. A competition outside this set is
    /// shown (so the roadmap is visible) but not pickable.
    let playableLeagues: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var all: [LeagueIdentity] { TeamIdentityIndex.shared.allLeagues(sport: sport) }

    private var matches: [LeagueIdentity] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter {
            ($0.displayName ?? "").localizedCaseInsensitiveContains(q)
                || ($0.country ?? $0.league).localizedCaseInsensitiveContains(q)
        }
    }

    /// Nation → its competitions, ordered by tier. Nations we can actually play come first:
    /// straight alphabetical buried the handful of playable leagues under ~30 nations of SOON
    /// rows, so the first screenful was entirely unusable options. Within each half the order
    /// stays alphabetical (from `allLeagues`), keeping the list predictable to scan.
    private var grouped: [(nation: String, leagues: [LeagueIdentity])] {
        var order: [String] = []
        var bucket: [String: [LeagueIdentity]] = [:]
        for league in matches {
            let nation = league.country ?? league.league
            if bucket[nation] == nil { order.append(nation) }
            bucket[nation, default: []].append(league)
        }
        let playableNations = order.filter { nation in
            (bucket[nation] ?? []).contains { playableLeagues.contains($0.league) }
        }
        let rest = order.filter { !playableNations.contains($0) }
        return (playableNations + rest).map { ($0, bucket[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: String(localized: "All leagues"), subtitle: nil, logo: nil,
                        selected: selection == nil, enabled: true) {
                        selection = nil
                        dismiss()
                    }
                }
                ForEach(grouped, id: \.nation) { group in
                    Section(group.nation.uppercased()) {
                        ForEach(group.leagues) { league in
                            // Tier 1 only: the arcade filter carries a COUNTRY label
                            // (`CatalogSeason.league`), not a competition, so every tier of a
                            // nation resolves to the same rows. Marking a lower division
                            // selectable would silently hand back the top flight's players —
                            // it stays SOON until player rows carry their competition.
                            let playable = playableLeagues.contains(league.league) && league.tier == 1
                            row(title: league.displayName ?? league.league,
                                subtitle: league.tier > 1
                                    ? String(localized: "Tier \(league.tier)") : nil,
                                logo: league.logoURL,
                                selected: selection == league.league && playable,
                                enabled: playable) {
                                selection = league.league
                                dismiss()
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text("League"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("Search leagues"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(title: String, subtitle: String?, logo: URL?, selected: Bool,
                     enabled: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: { if enabled { onTap() } }) {
            HStack(spacing: 12) {
                crest(logo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body14)
                        .foregroundStyle(enabled ? Color.textPrimary : Color.textMuted)
                    if let subtitle {
                        Text(subtitle).font(.label11).foregroundStyle(Color.textMuted)
                    }
                }
                Spacer()
                if !enabled {
                    // Honest about the roadmap: the competition exists, the content doesn't yet.
                    Text("SOON").font(.label11).foregroundStyle(Color.textMuted)
                } else if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func crest(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFit() } else { Color.clear }
            }
            .frame(width: 24, height: 24)
        } else {
            // Keeps every row's text on the same baseline whether or not a crest resolved.
            Color.clear.frame(width: 24, height: 24)
        }
    }
}
