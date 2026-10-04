import SwiftUI

/// A small team surface built on the existing preferences, identity index and puzzle repository.
struct HomeTeamSection: View {
    @EnvironmentObject private var container: RepositoryContainer
    let sport: Sport
    @State private var selectedSport: Sport?
    @State private var pickingTeam = false
    @State private var identities: [TeamIdentity] = []
    private var teamSport: Sport {
        if let selectedSport { return selectedSport }
        if sport.hasTeams, container.favoriteTeams.team(for: sport) != nil { return sport }
        return Sport.allCases.first { $0.hasTeams && container.favoriteTeams.team(for: $0) != nil }
            ?? (sport.hasTeams ? sport : .nfl)
    }
    private var team: String? { container.favoriteTeams.team(for: teamSport) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("YOUR TEAM").font(.label12).foregroundStyle(Color.textMuted)
                Spacer()
                Menu {
                    ForEach(Sport.allCases.filter(\.hasTeams)) { candidate in
                        Button(candidate.displayName) { selectedSport = candidate }
                    }
                } label: {
                    Label(teamSport.displayName, systemImage: "chevron.down").font(.label12)
                }
            }
            if let team {
                NavigationLink {
                    TeamHubView(sport: teamSport, teamAbbr: team)
                        .environmentObject(container)
                } label: {
                    TeamHubHeader(sport: teamSport, teamAbbr: team,
                                  subtitle: "Explore your team's K4C4 collection",
                                  identity: identities.first { $0.abbr == team })
                }
                .buttonStyle(PrimePressStyle())
                Button("Change team") { pickingTeam = true }.font(.label12)
            } else {
                Button { pickingTeam = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "star.fill").font(.title)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PICK YOUR \(teamSport.displayName.uppercased()) TEAM").font(.heading)
                            Text("A collection in your colors, devoted to your club.").font(.body14)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(Color.textPrimary).padding(16).cardSurface()
                }
                .buttonStyle(PrimePressStyle())
            }
        }
        .task(id: teamSport) { identities = await container.catalog.teamIdentities(for: teamSport) }
        .sheet(isPresented: $pickingTeam) {
            TeamPicker(selection: Binding(
                get: { container.favoriteTeams.team(for: teamSport) },
                set: { value in
                    var favorites = container.favoriteTeams
                    favorites.setTeam(value, for: teamSport)
                    Task { await container.saveFavoriteTeams(favorites) }
                }), sport: teamSport, fallbackAbbrs: container.catalog.teams(for: teamSport))
        }
    }
}

struct TeamHubHeader: View {
    let sport: Sport
    let teamAbbr: String
    let subtitle: String
    var identity: TeamIdentity? = nil
    private var palette: TeamPalette { TeamColors.palette(sport: sport, abbr: teamAbbr, league: nil) }
    private var name: String {
        identity?.fullName ?? TeamIdentityIndex.shared.identity(sport: sport, abbr: teamAbbr, league: nil)?.fullName ?? teamAbbr
    }
    var body: some View {
        HStack(spacing: 12) {
            TeamLogoBadge(sport: sport, teamAbbr: teamAbbr, tint: palette.onPrimary, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(name.uppercased()).font(.title)
                    .multilineTextAlignment(.leading)
                Text(subtitle).font(.body14).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.onPrimary)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockCard(fill: palette.primary)
    }
}
