import SwiftUI

/// Player headshot in a team-tinted circle. Shared by every card that shows a player photo
/// (Keep4, Over/Under, Draft & Spin, WhoAmI reveal) — one implementation instead of a
/// per-card copy (AGENTS.md §4). Originally lived only on `Keep4CardView`; extracted so
/// newer formats get the same "best feature" treatment.
///
/// When no photo exists (pre-2002 NBA has no photo source at all; a handful of NFL rows
/// resist even the name+era registry join), the fallback is the player's INITIALS in the
/// team tint — a deliberate monogram, not the gray person glyph that read as broken UI
/// ("no blank headshots", user directive 2026-07-18). The glyph remains only when no name
/// is available either.
struct PlayerHeadshotBadge: View {
    let headshot: String?
    let tint: Color
    var size: CGFloat = 48
    var name: String? = nil

    private var initials: String {
        guard let name else { return "" }
        let parts = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = [parts.first, parts.count > 1 ? parts.last : nil]
            .compactMap { $0?.first.map(String.init) }
        return letters.joined().uppercased()
    }

    @ViewBuilder private var fallback: some View {
        if initials.isEmpty {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.46))
                .foregroundStyle(tint.opacity(0.55))
        } else {
            Text(initials)
                .font(.custom(FontName.condBlack, size: size * 0.38))
                .foregroundStyle(tint)
        }
    }

    var body: some View {
        Group {
            if let headshot, let url = URL(string: headshot) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(tint.opacity(0.15))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1))
        .accessibilityHidden(true)   // decorative — the player's name is already read as text
    }
}

/// Team logo for sports with real clubs, or a country flag badge for sports without one
/// (tennis — `teamAbbr` holds a country code there, see `Sport.hasTeams`) — the same faint
/// disc treatment as `PlayerHeadshotBadge`, extracted from `Keep4CardView` for reuse.
struct TeamLogoBadge: View {
    let sport: Sport
    let teamAbbr: String
    let tint: Color
    var size: CGFloat = 40

    private var abbrText: some View {
        Text(teamAbbr.uppercased())
            .font(.custom(FontName.condBlack, size: size * 0.3))
            .foregroundStyle(tint)
    }

    /// ESPN team-logo CDN 404s (defunct teams like the Sonics) degrade to the abbr badge,
    /// never an empty disc — mirrors the original `Keep4CardView.teamLogoView` fallback chain.
    @ViewBuilder private var content: some View {
        if sport.hasTeams {
            if let url = sport.teamLogoURL(forAbbr: teamAbbr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: abbrText
                    default: Color.clear
                    }
                }
            } else {
                abbrText
            }
        } else if let flag = CountryFlags.flag(for: teamAbbr) {
            Text(flag).font(.system(size: size * 0.6))
        } else {
            abbrText
        }
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.15))   // faint disc, not a heavy white badge
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)   // decorative — team/country is already read as text
    }
}

/// A team abbreviation rendered as its own real color chip — Grid's board/recap row headers
/// ("CLE", "SEA") used to render these as plain ink-on-neutral text, the one team-identity
/// surface in the app that skipped `TeamColors` entirely. One shared shape instead of a
/// per-view copy (AGENTS.md §4), since Grid needs the identical chip at two sizes (the live
/// board and the post-game recap).
struct TeamAbbrChip: View {
    let sport: Sport
    let abbr: String
    var fontSize: CGFloat = 14
    var minHeight: CGFloat = 44

    private var team: TeamPalette { TeamColors.palette(sport: sport, abbr: abbr) }

    var body: some View {
        Text(abbr.uppercased())
            .font(.custom(FontName.condBlack, size: fontSize))
            .foregroundStyle(team.onPrimary)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(team.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
