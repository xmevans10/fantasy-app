import SwiftUI

/// Searchable club picker, sectioned by competition — the Club step of the FIFA-style
/// Nation → League → Club hierarchy, and the sibling of `LeaguePicker`.
///
/// Replaces a plain SwiftUI `Menu` that listed every club abbreviation flat and unsearchable.
/// That was tolerable at NFL's 32, but soccer carries **201 clubs**: a 201-item menu of bare
/// three-letter codes ("ARS", "BRO", "GRÊ") with no names, no crests and no search is not a
/// picker, it's a memory test. Rows here carry the real crest and full club name, sections carry
/// the competition, and search matches either.
///
/// Falls back to plain abbreviations when identity hasn't warmed yet (cold launch/offline), so
/// the control still works — it just looks like the old one until the catalog lands.
struct TeamPicker: View {
    @Binding var selection: String?
    let sport: Sport
    /// Abbreviations the catalog knows, used when team identity hasn't been fetched yet.
    let fallbackAbbrs: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var identities: [TeamIdentity] { TeamIdentityIndex.shared.allTeams(sport: sport) }

    private var matches: [TeamIdentity] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return identities }
        return identities.filter {
            ($0.fullName ?? "").localizedCaseInsensitiveContains(q)
                || $0.abbr.localizedCaseInsensitiveContains(q)
                || $0.league.localizedCaseInsensitiveContains(q)
        }
    }

    /// Competition → its clubs. US sports carry league "" and collapse into one unlabelled
    /// section, which is correct: they have exactly one competition.
    private var grouped: [(league: String, teams: [TeamIdentity])] {
        var order: [String] = []
        var bucket: [String: [TeamIdentity]] = [:]
        for team in matches {
            if bucket[team.league] == nil { order.append(team.league) }
            bucket[team.league, default: []].append(team)
        }
        return order.map { ($0, bucket[$0] ?? []) }
    }

    private var fallbackMatches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? fallbackAbbrs : fallbackAbbrs.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                noneSection
                if identities.isEmpty { fallbackSection } else { groupedSections }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text("Team"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("Search teams"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    // The List's content is split across these three properties rather than written inline:
    // as one expression it blew past SwiftUI's type-checker budget ("unable to type-check this
    // expression in reasonable time").

    @ViewBuilder
    private var noneSection: some View {
        Section {
            row(title: String(localized: "None"), subtitle: nil, logo: nil,
                selected: selection == nil) { selection = nil; dismiss() }
        }
    }

    /// Identity hasn't warmed yet — plain abbreviations, same as the control this replaced.
    @ViewBuilder
    private var fallbackSection: some View {
        Section {
            ForEach(fallbackMatches, id: \.self) { abbr in
                fallbackRow(abbr)
            }
        }
    }

    @ViewBuilder
    private func fallbackRow(_ abbr: String) -> some View {
        row(title: abbr, subtitle: nil, logo: sport.teamLogoURL(forAbbr: abbr),
            selected: selection == abbr) { selection = abbr; dismiss() }
    }

    @ViewBuilder
    private var groupedSections: some View {
        ForEach(grouped, id: \.league) { group in
            Section(displayName(for: group.league)) {
                ForEach(group.teams, id: \.id) { team in
                    teamRow(team)
                }
            }
        }
    }

    /// Its own function, not inlined in the `ForEach`: nesting the row builder inside two
    /// `ForEach`es blew past SwiftUI's type-checker budget ("unable to type-check this
    /// expression in reasonable time").
    @ViewBuilder
    private func teamRow(_ team: TeamIdentity) -> some View {
        let title = team.fullName ?? team.abbr
        let subtitle: String? = team.fullName == nil ? nil : team.abbr
        row(title: title, subtitle: subtitle, logo: team.logoURL,
            selected: selection == team.abbr) {
            selection = team.abbr
            dismiss()
        }
    }

    /// Section header: the competition's broadcast name when identity has it, else the raw
    /// league label. Empty (US sports) renders no header rather than a blank one.
    private func displayName(for league: String) -> String {
        guard !league.isEmpty else { return "" }
        return TeamIdentityIndex.shared.leagueIdentity(sport: sport, league: league)?.displayName
            ?? league
    }

    @ViewBuilder
    private func row(title: String, subtitle: String?, logo: URL?, selected: Bool,
                     onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let logo {
                    RemoteImage(url: logo, targetSize: CGSize(width: 24, height: 24))
                        .frame(width: 24, height: 24)
                } else {
                    Color.clear.frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body14).foregroundStyle(Color.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.label11).foregroundStyle(Color.textMuted)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentText) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
