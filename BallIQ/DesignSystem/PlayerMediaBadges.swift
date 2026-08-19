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
                RemoteImage(url: url, targetSize: CGSize(width: size, height: size),
                            contentMode: .fill,
                            placeholder: { fallback }, failure: { fallback })
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
    /// Disambiguates abbreviation collisions across leagues/countries when resolving the
    /// data-driven crest (`Sport.teamLogoURL(forAbbr:league:)` already tolerates nil — this
    /// just narrows the lookup when a caller happens to have one).
    var league: String? = nil
    var size: CGFloat = 40
    /// Set false when the crest for this code would be *wrong* rather than merely missing —
    /// Journeyman's era-renamed franchises, where `nfl/hou` is the Texans' badge and the label
    /// next to it says "Oilers". Falls through to the abbreviation chip, which is the same
    /// fallback a 404 already produces, so the two cases render identically.
    var showsLogo: Bool = true

    private var abbrText: some View {
        Text(teamAbbr.uppercased())
            .font(.custom(FontName.condBlack, size: size * 0.3))
            .foregroundStyle(tint)
    }

    /// ESPN team-logo CDN 404s (defunct teams like the Sonics) degrade to the abbr badge,
    /// never an empty disc — mirrors the original `Keep4CardView.teamLogoView` fallback chain.
    /// `teamLogoURL` itself already prefers the fetched `teams.logo_url` over the CDN guess.
    @ViewBuilder private var content: some View {
        if sport.hasTeams {
            if showsLogo, let url = sport.teamLogoURL(forAbbr: teamAbbr, league: league) {
                RemoteImage(url: url, targetSize: CGSize(width: size, height: size),
                            failure: { abbrText })
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
    /// Threaded through to both the data-driven color lookup and (when `showLogo`) the crest
    /// fetch — same collision rationale as `TeamLogoBadge.league`.
    var league: String? = nil
    var fontSize: CGFloat = 14
    var minHeight: CGFloat = 44
    /// Small crest to the left of the abbreviation — opt-in since Grid's board needs the plain
    /// color chip's full-width legibility at its smallest size; a recap row (or any future
    /// consumer with more room) can turn this on instead of duplicating the chip.
    var showLogo: Bool = false
    /// Overrides the rendered text while `abbr` still drives colors and the crest.
    ///
    /// Needed because a soccer code is not unique: The Grid renders league-qualified labels
    /// ("MCI-ENG" vs "MCI-AUS") so two clubs sharing a code are distinguishable on the board,
    /// but the palette and crest lookups must key on the raw "MCI" the `teams` table stores.
    var displayText: String? = nil

    private var team: TeamPalette { TeamColors.palette(sport: sport, abbr: abbr, league: league) }
    private var logoURL: URL? { showLogo ? sport.teamLogoURL(forAbbr: abbr, league: league) : nil }

    var body: some View {
        HStack(spacing: 4) {
            if let logoURL {
                RemoteImage(url: logoURL,
                            targetSize: CGSize(width: minHeight * 0.5, height: minHeight * 0.5))
                    .frame(width: minHeight * 0.5, height: minHeight * 0.5)
            }
            Text((displayText ?? abbr).uppercased())
                .font(.custom(FontName.condBlack, size: fontSize))
                .foregroundStyle(team.onPrimary)
                // A qualified label ("MCI-ENG") is meaningfully longer than a bare code, so it
                // scales further down before truncating rather than losing the nation suffix —
                // which is the part that disambiguates it.
                .lineLimit(1).minimumScaleFactor(0.45)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(team.primary)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// League/competition crest (e.g. an NFL shield, a soccer confederation badge) — the same faint-
/// disc treatment as `TeamLogoBadge`, for the surfaces that show league-level rather than
/// team-level identity. Falls back to the league's display name (or its raw code, pre-fetch) as
/// text rather than a broken image.
struct LeagueLogoBadge: View {
    let sport: Sport
    let league: String
    let tint: Color
    var size: CGFloat = 40

    private var identity: LeagueIdentity? { TeamIdentityIndex.shared.leagueIdentity(sport: sport, league: league) }

    private var fallbackText: some View {
        Text((identity?.displayName ?? league).uppercased())
            .font(.custom(FontName.condBlack, size: size * 0.22))
            .foregroundStyle(tint)
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 2)
    }

    @ViewBuilder private var content: some View {
        if let url = identity?.logoURL {
            RemoteImage(url: url, targetSize: CGSize(width: size, height: size),
                        failure: { fallbackText })
        } else {
            fallbackText
        }
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.15))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)   // decorative — the league is already read as text nearby
    }
}
