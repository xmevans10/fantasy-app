import SwiftUI

/// Team-at-the-time color identity for K4C4 cards. We deliberately use color (not logos or
/// headshots) as the franchise signal — no licensed assets, instant recognizability, and it
/// fits the "Prime Time" broadcast look. Keyed by (sport, abbreviation) because several
/// abbreviations collide across leagues (CHI, DAL, MIN, PHI, WAS …).
struct TeamPalette: Equatable {
    let primary: Color
    let secondary: Color
    let onPrimary: Color      // legible text/icon on `primary`
    let onSecondary: Color    // legible text/icon on `secondary` — NOT always onPrimary's
                              // inverse: several teams' secondary trends the same dark/light
                              // direction as their primary (e.g. Carolina's teal primary +
                              // near-black secondary both want white text), so this is its
                              // own real luminance check, not a guessed opposite.
}

enum TeamColors {
    static func palette(sport: Sport, abbr: String) -> TeamPalette {
        let key = normalize(abbr, sport: sport)
        guard let pair = table(for: sport)[key] else { return fallback }
        return TeamPalette(primary: Color(hex: pair.0),
                           secondary: Color(hex: pair.1),
                           onPrimary: onColor(for: pair.0),
                           onSecondary: onColor(for: pair.1))
    }

    /// Neutral slate for unknown/old franchises — still on-brand, never a blank card.
    static let fallback = TeamPalette(primary: Color(hex: 0x2B2B2A),
                                      secondary: Color(hex: 0x1E50FF),
                                      onPrimary: .white,
                                      onSecondary: .white)

    // MARK: - Legibility

    /// Near-black ink on light team colors, white on dark ones (perceptual luma).
    private static func onColor(for hex: UInt32) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        return luma > 0.6 ? Color(hex: 0x15120B) : .white
    }

    // MARK: - Abbreviation normalization (catalog/nflverse use historical variants)

    private static func normalize(_ abbr: String, sport: Sport) -> String {
        let up = abbr.uppercased()
        let aliases: [String: String]
        switch sport {
        case .nfl:
            aliases = ["LA": "LAR", "STL": "LAR", "OAK": "LV", "LVR": "LV", "SD": "LAC", "SDG": "LAC",
                       "WSH": "WAS", "JAC": "JAX", "ARZ": "ARI", "GNB": "GB", "KAN": "KC", "NWE": "NE",
                       "NOR": "NO", "SFO": "SF", "TAM": "TB", "CLV": "CLE", "BLT": "BAL", "HST": "HOU"]
        case .nba:
            aliases = ["NO": "NOP", "NOH": "NOP", "NJN": "BKN", "NYN": "BKN", "PHO": "PHX", "SAN": "SAS",
                       "GS": "GSW", "NY": "NYK", "UTAH": "UTA", "CHO": "CHA", "SEA": "OKC"]
        case .baseball, .soccer, .tennis:
            aliases = [:]   // no historical-franchise collisions to normalize yet
        }
        return aliases[up] ?? up
    }

    // MARK: - Tables (primary, secondary) hex

    private static func table(for sport: Sport) -> [String: (UInt32, UInt32)] {
        switch sport {
        case .nfl: return nfl
        case .nba: return nba
        case .baseball: return mlb
        case .soccer: return soccer
        case .tennis: return [:]   // no team/club — every lookup falls through to `fallback`
        }
    }

    private static let nfl: [String: (UInt32, UInt32)] = [
        "ARI": (0x97233F, 0x000000), "ATL": (0xA71930, 0x000000), "BAL": (0x241773, 0x9E7C0C),
        "BUF": (0x00338D, 0xC60C30), "CAR": (0x0085CA, 0x101820), "CHI": (0x0B162A, 0xC83803),
        "CIN": (0xFB4F14, 0x000000), "CLE": (0x311D00, 0xFF3C00), "DAL": (0x003594, 0x869397),
        "DEN": (0xFB4F14, 0x002244), "DET": (0x0076B6, 0xB0B7BC), "GB":  (0x203731, 0xFFB612),
        "HOU": (0x03202F, 0xA71930), "IND": (0x002C5F, 0xA2AAAD), "JAX": (0x101820, 0xD7A22A),
        "KC":  (0xE31837, 0xFFB81C), "LV":  (0x000000, 0xA5ACAF), "LAC": (0x0080C6, 0xFFC20E),
        "LAR": (0x003594, 0xFFA300), "MIA": (0x008E97, 0xFC4C02), "MIN": (0x4F2683, 0xFFC62F),
        "NE":  (0x002244, 0xC60C30), "NO":  (0xD3BC8D, 0x101820), "NYG": (0x0B2265, 0xA71930),
        "NYJ": (0x125740, 0x000000), "PHI": (0x004C54, 0xA5ACAF), "PIT": (0xFFB612, 0x101820),
        "SEA": (0x002244, 0x69BE28), "SF":  (0xAA0000, 0xB3995D), "TB":  (0xD50A0A, 0x34302B),
        "TEN": (0x0C2340, 0x4B92DB), "WAS": (0x5A1414, 0xFFB612),
    ]

    private static let nba: [String: (UInt32, UInt32)] = [
        "ATL": (0xE03A3E, 0xC1D32F), "BOS": (0x007A33, 0xBA9653), "BKN": (0x000000, 0x888888),
        "CHA": (0x1D1160, 0x00788C), "CHI": (0xCE1141, 0x000000), "CLE": (0x860038, 0xFDBB30),
        "DAL": (0x00538C, 0x002B5E), "DEN": (0x0E2240, 0xFEC524), "DET": (0xC8102E, 0x1D42BA),
        "GSW": (0x1D428A, 0xFFC72C), "HOU": (0xCE1141, 0x000000), "IND": (0x002D62, 0xFDBB30),
        "LAC": (0xC8102E, 0x1D428A), "LAL": (0x552583, 0xFDB927), "MEM": (0x5D76A9, 0x12173F),
        "MIA": (0x98002E, 0xF9A01B), "MIL": (0x00471B, 0xEEE1C6), "MIN": (0x0C2340, 0x236192),
        "NOP": (0x0C2340, 0xC8102E), "NYK": (0x006BB6, 0xF58426), "OKC": (0x007AC1, 0xEF3B24),
        "ORL": (0x0077C0, 0xC4CED4), "PHI": (0x006BB6, 0xED174C), "PHX": (0x1D1160, 0xE56020),
        "POR": (0xE03A3E, 0x000000), "SAC": (0x5A2D81, 0x63727A), "SAS": (0xC4CED4, 0x000000),
        "TOR": (0xCE1141, 0x000000), "UTA": (0x002B5C, 0x00471B), "WAS": (0x002B5C, 0xE31837),
    ]

    /// All 30 MLB clubs — matches `providers/mlb_stats.py`'s `TEAM_ABBR` id table exactly.
    private static let mlb: [String: (UInt32, UInt32)] = [
        "LAA": (0xBA0021, 0x003263), "AZ":  (0xA71930, 0x000000), "BAL": (0xDF4601, 0x000000),
        "BOS": (0xBD3039, 0x0D2B56), "CHC": (0x0E3386, 0xCC3433), "CIN": (0xC6011F, 0x000000),
        "CLE": (0x00385D, 0xE50022), "COL": (0x33006F, 0x000000), "DET": (0x0C2340, 0xFA4616),
        "HOU": (0x002D62, 0xEB6E1F), "KC":  (0x004687, 0xBD9B60), "LAD": (0x005A9C, 0xEF3E42),
        "WSH": (0xAB0003, 0x14225A), "NYM": (0x002D72, 0xFF5910), "ATH": (0x003831, 0xEFB21E),
        "PIT": (0x27251F, 0xFDB827), "SD":  (0x2F241D, 0xFFC425), "SEA": (0x0C2C56, 0x005C5C),
        "SF":  (0xFD5A1E, 0x000000), "STL": (0xC41E3A, 0x0C2340), "TB":  (0x092C5C, 0x8FBCE6),
        "TEX": (0x003278, 0xC0111F), "TOR": (0x134A8E, 0xE8291C), "MIN": (0x002B5C, 0xD31145),
        "PHI": (0xE81828, 0x002D72), "ATL": (0x13274F, 0xCE1141), "CWS": (0x27251F, 0xC4CED4),
        "MIA": (0x00A3E0, 0xEF3340), "NYY": (0x0C2340, 0xC4CED3), "MIL": (0x0A2351, 0xB6922E),
    ]

    /// A handful of clubs the seed-only soccer content actually references — not a full
    /// league table (no live soccer provider yet, see `providers/seed.py`).
    private static let soccer: [String: (UInt32, UInt32)] = [
        "MCI": (0x6CABDD, 0x1C2C5B), "FCB": (0x004D98, 0xA50044), "RMA": (0xFEBE10, 0x00529F),
        "LIV": (0xC8102E, 0xF6EB61), "BAY": (0xDC052D, 0x0066B2), "PSG": (0x004170, 0xDA291C),
        "TOT": (0x132257, 0xFFFFFF), "CHE": (0x034694, 0xDBA111), "MUN": (0xDA291C, 0xFBE122),
        "BUR": (0x6C1D45, 0x99D6EA), "AVL": (0x670E36, 0x95BFE5),
    ]
}
