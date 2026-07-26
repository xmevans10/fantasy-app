import SwiftUI

/// The filter a Nation → League → Club drill-down produces. Each level is optional and narrows
/// the one above it, so "Germany" and "Germany → Bundesliga → Bayern" are both valid states.
struct ClubFilter: Equatable {
    /// Nation label — what `CatalogSeason.league` stores. Selecting a nation matches EVERY
    /// division under it (both Bundesliga and 2. Bundesliga rows read "Germany"), which is
    /// what "All of Germany" should mean.
    var nation: String?
    /// Competition key ("ger.1") — `CatalogSeason.competition`, the division. This is the
    /// level a nation cannot express, and it is enforced whenever it's set.
    var competition: String?
    /// Club abbreviation — the narrowest level.
    var club: String?

    static let all = ClubFilter()
    var isAll: Bool { self == .all }

    /// Does this season fall inside the selection? Each level that is set must match, so the
    /// three compose: nation alone = every division of that country; nation + competition =
    /// one division; + club = one team.
    ///
    /// A `nil` value on the SEASON never matches a set level — a soccer row written before the
    /// `competition` column existed genuinely doesn't know its division, and quietly letting it
    /// through would put Bundesliga players in a 2. Bundesliga draft. `spinRound`'s
    /// fall-back-to-the-full-pool behavior is what keeps that strictness from dead-ending a
    /// spin while the backfill is still catching up.
    func matches(_ season: CatalogSeason) -> Bool {
        if let nation, season.league != nation { return false }
        if let competition, season.competition != competition { return false }
        if let club, season.teamAbbr != club { return false }
        return true
    }

    /// What this selection is called, deepest level first: club → competition → nation → all.
    /// Lives on the filter rather than in the picker button because the setup screen's caption
    /// has to name the same thing the button shows — two copies drifted the moment competitions
    /// became selectable and only the button knew about them.
    func displayName(sport: Sport) -> String {
        if let club {
            return TeamIdentityIndex.shared.identity(sport: sport, abbr: club,
                                                     league: nation)?.fullName ?? club
        }
        guard let nation else { return String(localized: "All leagues") }
        if let competition,
           let match = TeamIdentityIndex.shared.leagues(sport: sport, nation: nation)
               .first(where: { $0.competition == competition }) {
            return match.displayName ?? nation
        }
        return nation
    }
}

/// Nation → League → Club, as navigation rather than one flat list.
///
/// The app's league control used to be a 2-column grid of 10 hardcoded chips over a single flat
/// value. That cannot express the hierarchy the data now has (44 competitions across 37 nations,
/// with division ladders), and it cannot express a club at all. This walks the three levels the
/// way iOS walks any hierarchy — a `NavigationStack` of searchable lists, each row carrying the
/// real crest for that level.
struct NationLeagueClubPicker: View {
    @Binding var filter: ClubFilter
    let sport: Sport
    /// Nation labels the catalog holds player rows for; anything else is shown but not pickable.
    let playableNations: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Drives the drill-down so an automated run can land on the DIVISION level directly —
    /// see `DebugLaunch.screenshotLeagueNation`. Normal taps push onto the same path.
    @State private var path: [String] = []

    private var nations: [String] { TeamIdentityIndex.shared.nations(sport: sport) }

    private var matchingNations: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nations }
        // Match the nation or any of its competitions, so typing "Bundesliga" finds Germany.
        return nations.filter { nation in
            nation.localizedCaseInsensitiveContains(q)
                || TeamIdentityIndex.shared.leagues(sport: sport, nation: nation)
                    .contains { ($0.displayName ?? "").localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        filter = .all
                        dismiss()
                    } label: {
                        PickerRow(title: String(localized: "All leagues"), subtitle: nil,
                                  logo: nil, trailing: filter.isAll ? .check : .none)
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    ForEach(matchingNations, id: \.self) { nation in
                        nationRow(nation)
                    }
                }
            }
            .navigationDestination(for: String.self) { nation in
                LeagueLevel(filter: $filter, sport: sport, nation: nation,
                            playable: playableNations.contains(nation),
                            dismissAll: { dismiss() })
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text("League"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("Search nations & leagues"))
            .onAppear {
                if let nation = DebugLaunch.screenshotLeagueNation, path.isEmpty {
                    path = [nation]
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func nationRow(_ nation: String) -> some View {
        let playable = playableNations.contains(nation)
        let crest = TeamIdentityIndex.shared.leagues(sport: sport, nation: nation).first?.logoURL
        NavigationLink(value: nation) {
            PickerRow(title: nation, subtitle: nil, logo: crest,
                      trailing: playable ? (filter.nation == nation ? .check : .none) : .soon)
        }
        .disabled(!playable)
    }
}

// MARK: - Level 2: competitions inside a nation

private struct LeagueLevel: View {
    @Binding var filter: ClubFilter
    let sport: Sport
    let nation: String
    let playable: Bool
    let dismissAll: () -> Void

    private var leagues: [LeagueIdentity] {
        TeamIdentityIndex.shared.leagues(sport: sport, nation: nation)
    }

    /// Read live, NOT passed in from the setup screen: a `Set` handed to `.sheet` is captured
    /// when the sheet is presented, and identity warms asynchronously — so an auto-opened
    /// picker captured an empty set and rendered every division "SOON" (caught in the
    /// simulator 2026-07-26). The nation level hid the same bug behind its curated fallback.
    private var playableCompetitions: Set<String> {
        TeamIdentityIndex.shared.competitionsWithTeams(sport: sport)
    }

    var body: some View {
        List {
            Section {
                Button {
                    // Nation-wide: the level the arcade filter can actually enforce today.
                    filter = ClubFilter(nation: nation, competition: nil, club: nil)
                    dismissAll()
                } label: {
                    PickerRow(title: String(localized: "All of \(nation)"), subtitle: nil,
                              logo: nil,
                              trailing: filter.nation == nation && filter.competition == nil
                                  && filter.club == nil ? .check : .none)
                }
                .buttonStyle(.plain)
            }
            Section {
                ForEach(leagues) { league in
                    leagueRow(league)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(nation))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func leagueRow(_ league: LeagueIdentity) -> some View {
        // Every tier whose competition actually has player rows is selectable now that rows
        // carry `competition`. Before that column was populated a lower division would have
        // silently returned the top flight's players, so only tier 1 could be offered.
        let selectable = playable && playableCompetitions.contains(league.competition ?? "")
        NavigationLink {
            ClubLevel(filter: $filter, sport: sport, nation: nation,
                      competition: league.competition, leagueName: league.displayName ?? nation,
                      dismissAll: dismissAll)
        } label: {
            PickerRow(title: league.displayName ?? league.league,
                      subtitle: league.tier > 1 ? String(localized: "Tier \(league.tier)") : nil,
                      logo: league.logoURL,
                      trailing: selectable ? .none : .soon)
        }
        .disabled(!selectable)
    }
}

// MARK: - Level 3: clubs inside a competition

private struct ClubLevel: View {
    @Binding var filter: ClubFilter
    let sport: Sport
    let nation: String
    let competition: String?
    let leagueName: String
    let dismissAll: () -> Void

    private var clubs: [TeamIdentity] {
        TeamIdentityIndex.shared.clubs(sport: sport, competition: competition, nation: nation)
    }

    var body: some View {
        List {
            Section {
                Button {
                    filter = ClubFilter(nation: nation, competition: competition, club: nil)
                    dismissAll()
                } label: {
                    PickerRow(title: String(localized: "All clubs"), subtitle: nil, logo: nil,
                              trailing: filter.club == nil && filter.nation == nation
                                  && filter.competition == competition ? .check : .none)
                }
                .buttonStyle(.plain)
            }
            Section {
                ForEach(clubs) { club in
                    Button {
                        filter = ClubFilter(nation: nation, competition: competition,
                                            club: club.abbr)
                        dismissAll()
                    } label: {
                        PickerRow(title: club.fullName ?? club.abbr, subtitle: club.abbr,
                                  logo: club.logoURL,
                                  trailing: filter.club == club.abbr ? .check : .none)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(leagueName))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared row

/// One row at any of the three levels — same shape so a nation, a competition and a club all
/// read as the same kind of choice, only the crest changes.
struct PickerRow: View {
    enum Trailing { case none, check, soon }

    let title: String
    let subtitle: String?
    let logo: URL?
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            crest
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body14)
                    .foregroundStyle(trailing == .soon ? Color.textMuted : Color.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.label11).foregroundStyle(Color.textMuted)
                }
            }
            Spacer()
            switch trailing {
            case .check: Image(systemName: "checkmark").foregroundStyle(Color.accentText)
            case .soon: Text("SOON").font(.label11).foregroundStyle(Color.textMuted)
            case .none: EmptyView()
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var crest: some View {
        if let logo {
            AsyncImage(url: logo) { phase in
                if let img = phase.image { img.resizable().scaledToFit() } else { Color.clear }
            }
            .frame(width: 24, height: 24)
        } else {
            // Keeps every row's text on one baseline whether or not a crest resolved.
            Color.clear.frame(width: 24, height: 24)
        }
    }
}
