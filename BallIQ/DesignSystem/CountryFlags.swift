import Foundation

/// Flag emoji for teamless sports (today: tennis), whose `PlayerSeason.teamAbbr` holds a
/// 3-letter IOC/ATP-style country code instead of a club abbreviation (see `Sport.hasTeams`
/// and `providers/seed.py`'s `load_tennis` docstring). Covers the seed dataset's countries
/// plus other common tennis nations so this doesn't need a follow-up edit the moment the
/// player pool broadens.
enum CountryFlags {
    /// IOC code -> ISO 3166-1 alpha-2, which is what a flag emoji is actually built from.
    /// Historical codes (e.g. TCH = Czechoslovakia, dissolved 1993) map to the modern
    /// successor state as the closest available stand-in.
    private static let iocToISO2: [String: String] = [
        "USA": "US", "ESP": "ES", "SUI": "CH", "SRB": "RS", "SWE": "SE", "TCH": "CZ",
        "GBR": "GB", "FRA": "FR", "GER": "DE", "ITA": "IT", "AUS": "AU", "RUS": "RU",
        "ARG": "AR", "CAN": "CA", "JPN": "JP", "CHN": "CN", "CRO": "HR", "AUT": "AT",
        "BEL": "BE", "NED": "NL", "POR": "PT", "GRE": "GR", "POL": "PL", "CZE": "CZ",
        "SVK": "SK", "HUN": "HU", "ROU": "RO", "BUL": "BG", "UKR": "UA", "BLR": "BY",
        "DEN": "DK", "NOR": "NO", "FIN": "FI", "IRL": "IE", "RSA": "ZA", "BRA": "BR",
        "CHI": "CL", "MEX": "MX", "COL": "CO", "IND": "IN", "KOR": "KR", "NZL": "NZ",
        "URU": "UY", "ECU": "EC", "PER": "PE", "VEN": "VE", "TPE": "TW", "ISR": "IL",
        "TUR": "TR", "EGY": "EG", "MAR": "MA", "TUN": "TN", "GEO": "GE", "LAT": "LV",
        "LTU": "LT", "EST": "EE", "SLO": "SI", "MDA": "MD", "KAZ": "KZ", "MON": "MC",
        "LUX": "LU", "ISL": "IS", "CYP": "CY", "ALG": "DZ", "NGR": "NG",
    ]

    /// The flag emoji for an IOC code, or nil if unmapped (callers should fall back to
    /// showing the plain code as text rather than a broken/missing image).
    static func flag(for iocCode: String) -> String? {
        guard let iso2 = iocToISO2[iocCode.uppercased()] else { return nil }
        return emoji(fromISO2: iso2)
    }

    /// Builds the flag from two Regional Indicator Symbols (e.g. "US" -> 🇺🇸) — the
    /// standard emoji flag mechanism, needing no image assets.
    private static func emoji(fromISO2 code: String) -> String? {
        guard code.count == 2 else { return nil }
        var scalars: [Unicode.Scalar] = []
        for c in code.uppercased().unicodeScalars {
            guard c.value >= 65, c.value <= 90,
                  let scalar = Unicode.Scalar(0x1F1E6 + (c.value - 65)) else { return nil }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
