import XCTest
import SwiftUI
@testable import BallIQ

/// Data-driven team/league identity foundation (`Models/TeamIdentity.swift`, `TeamColors`,
/// `Sport.teamLogoURL`) — the pre-existing hardcoded tables stay in place as the offline/cold-
/// launch fallback, so most tests here inject their own `TeamIdentityIndex` rather than
/// `.shared`: that guarantees they can't leak fixture rows into `SportLogoTests`/
/// `TeamColorsTests`, which assert the pure-fallback path is unaffected by any fetched data.
@MainActor
final class TeamIdentityTests: XCTestCase {

    // MARK: - Decoding

    func testTeamIdentityDecodesHexColorsAndURL() throws {
        let json = #"""
        {"sport":"nfl","team_abbr":"SF","league":"","full_name":"San Francisco 49ers",
         "logo_url":"https://example.com/sf.png","primary_color":"#AA0000","secondary_color":"#B3995D"}
        """#.data(using: .utf8)!
        let row = try JSONDecoder.supabase.decode(TeamIdentity.Row.self, from: json)
        let identity = TeamIdentity(row: row)

        XCTAssertEqual(identity.sport, .nfl)
        XCTAssertEqual(identity.abbr, "SF")
        XCTAssertEqual(identity.fullName, "San Francisco 49ers")
        XCTAssertEqual(identity.logoURL?.absoluteString, "https://example.com/sf.png")
        XCTAssertEqual(identity.primary, Color(hex: 0xAA0000))
        XCTAssertEqual(identity.secondary, Color(hex: 0xB3995D))
    }

    func testTeamIdentityToleratesNullLogoAndColors() throws {
        let json = #"""
        {"sport":"soccer","team_abbr":"ZZZ","league":"England","full_name":null,
         "logo_url":null,"primary_color":null,"secondary_color":null}
        """#.data(using: .utf8)!
        let row = try JSONDecoder.supabase.decode(TeamIdentity.Row.self, from: json)
        let identity = TeamIdentity(row: row)

        XCTAssertNil(identity.fullName)
        XCTAssertNil(identity.logoURL)
        XCTAssertNil(identity.primary)
        XCTAssertNil(identity.secondary)
    }

    func testLeagueIdentityDecodes() throws {
        let json = #"""
        {"sport":"nfl","league":"","display_name":"NFL","logo_url":"https://example.com/nfl.png"}
        """#.data(using: .utf8)!
        let row = try JSONDecoder.supabase.decode(LeagueIdentity.Row.self, from: json)
        let identity = LeagueIdentity(row: row)

        XCTAssertEqual(identity.displayName, "NFL")
        XCTAssertEqual(identity.logoURL?.absoluteString, "https://example.com/nfl.png")
    }

    // MARK: - Hex string parsing

    func testColorHexStringToleratesMissingHashAndRejectsGarbage() {
        XCTAssertEqual(Color(hexString: "#AA0000"), Color(hex: 0xAA0000))
        XCTAssertEqual(Color(hexString: "AA0000"), Color(hex: 0xAA0000))
        XCTAssertNil(Color(hexString: "not-a-color"))
        XCTAssertNil(Color(hexString: "#AA00"))
    }

    // MARK: - League-tolerant lookup order

    /// Exact (abbr, league) match must win over both the blank-league row and the any-league
    /// last resort — "BRO" is the real cross-country collision (`CatalogSeason.league`'s own
    /// example) this ordering exists to protect against.
    func testIdentityLookupPrefersExactLeagueOverBlankOrAnyLeague() {
        let index = TeamIdentityIndex()
        let blank = TeamIdentity(sport: .soccer, abbr: "BRO", league: "",
                                 fullName: "Blank-league Rovers", logoURL: nil, primary: nil, secondary: nil)
        let england = TeamIdentity(sport: .soccer, abbr: "BRO", league: "England",
                                   fullName: "Blackburn Rovers", logoURL: nil, primary: nil, secondary: nil)
        let australia = TeamIdentity(sport: .soccer, abbr: "BRO", league: "Australia",
                                     fullName: "Brisbane Roar", logoURL: nil, primary: nil, secondary: nil)
        index.store(teams: [blank, england, australia])

        XCTAssertEqual(index.identity(sport: .soccer, abbr: "BRO", league: "England")?.fullName, "Blackburn Rovers")
        XCTAssertEqual(index.identity(sport: .soccer, abbr: "BRO", league: "Australia")?.fullName, "Brisbane Roar")
        XCTAssertEqual(index.identity(sport: .soccer, abbr: "BRO", league: nil)?.fullName, "Blank-league Rovers")
    }

    func testIdentityLookupFallsBackToBlankLeagueForUSSportsAndIsCaseInsensitive() {
        let index = TeamIdentityIndex()
        let sf = TeamIdentity(sport: .nfl, abbr: "SF", league: "", fullName: "San Francisco 49ers",
                              logoURL: nil, primary: Color(hex: 0xAA0000), secondary: nil)
        index.store(teams: [sf])

        // NFL/NBA/MLB rows carry league '' — a caller with no league (or the wrong one) must
        // still resolve via the blank-league fallback.
        XCTAssertEqual(index.identity(sport: .nfl, abbr: "SF", league: nil)?.fullName, "San Francisco 49ers")
        XCTAssertEqual(index.identity(sport: .nfl, abbr: "sf", league: "not-a-real-league")?.fullName,
                       "San Francisco 49ers")
    }

    /// `league(sport:abbr:)` exists because `player_seasons.league` is populated on only ~6% of
    /// soccer rows (the ESPN-sourced ones); the `teams` catalog is league-qualified for every
    /// club, so a club's competition must resolve from an abbreviation alone.
    func testLeagueForAbbrResolvesFromTheTeamsCatalogAndIsNilForUSSports() {
        let index = TeamIdentityIndex()
        index.store(teams: [
            TeamIdentity(sport: .soccer, abbr: "ARS", league: "England", fullName: "Arsenal",
                         logoURL: nil, primary: nil, secondary: nil),
            // US rows carry league '' — must read as "no competition", not an empty badge.
            TeamIdentity(sport: .nfl, abbr: "SF", league: "", fullName: "San Francisco 49ers",
                         logoURL: nil, primary: nil, secondary: nil),
        ])

        XCTAssertEqual(index.league(sport: .soccer, abbr: "ARS"), "England")
        XCTAssertEqual(index.league(sport: .soccer, abbr: "ars"), "England")   // case-insensitive
        XCTAssertNil(index.league(sport: .nfl, abbr: "SF"))
        XCTAssertNil(index.league(sport: .soccer, abbr: "NOPE"))
    }

    func testIdentityLookupReturnsNilWhenNothingStored() {
        let index = TeamIdentityIndex()
        XCTAssertNil(index.identity(sport: .nfl, abbr: "SF", league: nil))
        XCTAssertNil(index.leagueIdentity(sport: .nfl, league: ""))
    }

    // MARK: - TeamColors.palette: data-driven preferred, hardcoded fallback preserved

    func testPaletteWithLeaguePrefersFetchedColorsOverHardcodedTable() {
        let index = TeamIdentityIndex()
        // Deliberately WRONG vs. the real hardcoded SF 49ers red, so a passing assertion can
        // only mean the data-driven path actually won.
        index.store(teams: [TeamIdentity(sport: .nfl, abbr: "SF", league: "", fullName: nil, logoURL: nil,
                                         primary: Color(hex: 0x00FF00), secondary: Color(hex: 0x0000FF))])

        let palette = TeamColors.palette(sport: .nfl, abbr: "SF", league: nil, index: index)
        XCTAssertEqual(palette.primary, Color(hex: 0x00FF00))
        XCTAssertEqual(palette.secondary, Color(hex: 0x0000FF))
        XCTAssertNotEqual(palette, TeamColors.palette(sport: .nfl, abbr: "SF"))   // hardcoded table differs
    }

    func testPaletteWithLeagueFallsBackToHardcodedWhenIndexIsEmpty() {
        let index = TeamIdentityIndex()   // nothing stored
        let dataDriven = TeamColors.palette(sport: .nfl, abbr: "SF", league: nil, index: index)
        let hardcoded = TeamColors.palette(sport: .nfl, abbr: "SF")
        XCTAssertEqual(dataDriven, hardcoded)
    }

    /// A fetched team with no secondary color must mirror its primary, not silently reuse the
    /// hardcoded fallback's blue — `TeamPalette.onSecondary` still needs a real color to grade.
    func testPaletteWithLeagueMirrorsPrimaryWhenNoSecondaryFetched() {
        let index = TeamIdentityIndex()
        index.store(teams: [TeamIdentity(sport: .nba, abbr: "XYZ", league: "", fullName: nil, logoURL: nil,
                                         primary: Color(hex: 0x123456), secondary: nil)])
        let palette = TeamColors.palette(sport: .nba, abbr: "XYZ", league: nil, index: index)
        XCTAssertEqual(palette.primary, Color(hex: 0x123456))
        XCTAssertEqual(palette.secondary, Color(hex: 0x123456))
    }

    /// Regression guard for `TeamColorsTests`: the original 2-arg overload must stay
    /// pure-hardcoded no matter what any test (including this file) has stored elsewhere.
    func testTwoArgPaletteStaysHardcodedOnly() {
        XCTAssertEqual(TeamColors.palette(sport: .nfl, abbr: "CAR"),
                       TeamPalette(primary: Color(hex: 0x0085CA), secondary: Color(hex: 0x101820),
                                  onPrimary: .white, onSecondary: .white))
    }

    // MARK: - Sport.teamLogoURL: data-driven preferred, ESPN CDN fallback preserved

    func testTeamLogoURLPrefersFetchedLogoOverESPNCDN() {
        let index = TeamIdentityIndex()
        index.store(teams: [TeamIdentity(sport: .soccer, abbr: "RMA", league: "Spain", fullName: nil,
                                         logoURL: URL(string: "https://example.com/rma.png"),
                                         primary: nil, secondary: nil)])
        XCTAssertEqual(Sport.soccer.teamLogoURL(forAbbr: "RMA", league: "Spain", index: index)?.absoluteString,
                       "https://example.com/rma.png")
    }

    func testTeamLogoURLFallsBackToESPNCDNWhenIndexIsEmpty() {
        let index = TeamIdentityIndex()
        XCTAssertEqual(Sport.soccer.teamLogoURL(forAbbr: "RMA", index: index)?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/soccer/500/86.png")
    }

    // MARK: - PlayerSeasonCatalog fetch + cache

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamIdentityTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DiskCache.directoryOverride = dir
    }

    override func tearDown() {
        if let dir = DiskCache.directoryOverride {
            try? FileManager.default.removeItem(at: dir)
        }
        DiskCache.directoryOverride = nil
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// `teamIdentities(for:)` stores into the real `TeamIdentityIndex.shared` (that's the whole
    /// point — synchronous design-system lookups need a process-wide index). The fixture
    /// abbreviation is deliberately unique so it can never collide with anything
    /// `SportLogoTests`/`TeamColorsTests` looks up elsewhere in the same test process.
    func testTeamIdentitiesFetchPopulatesSharedIndex() async {
        MockURLProtocol.handler = { req in
            let json = ##"[{"sport":"nfl","team_abbr":"ZQXTEST","league":"","full_name":"Fixture FC","logo_url":null,"primary_color":"#112233","secondary_color":null}]"##
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let catalog = PlayerSeasonCatalog(client: makeClient())
        let items = await catalog.teamIdentities(for: .nfl)

        XCTAssertEqual(items.first?.abbr, "ZQXTEST")
        XCTAssertEqual(TeamIdentityIndex.shared.identity(sport: .nfl, abbr: "ZQXTEST", league: nil)?.fullName,
                       "Fixture FC")
        XCTAssertEqual(catalog.identity(sport: .nfl, abbr: "ZQXTEST")?.primary, Color(hex: 0x112233))
    }

    /// Same freshness contract as the arcade-pool cache (`DiskCacheTests`): a disk entry written
    /// "now" must be served without ever touching the network.
    func testTeamIdentitiesDiskCacheSkipsNetworkWhenFresh() async {
        let row = TeamIdentity.Row(sport: .nba, teamAbbr: "ZQXTEST2", league: "",
                                   fullName: "Cached Fixture", logoUrl: nil,
                                   primaryColor: nil, secondaryColor: nil, competition: nil)
        await DiskCache.write([row], key: "teams-nba")

        var hits = 0
        MockURLProtocol.handler = { req in
            hits += 1
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let catalog = PlayerSeasonCatalog(client: makeClient())
        let items = await catalog.teamIdentities(for: .nba)

        XCTAssertEqual(items.map(\.abbr), ["ZQXTEST2"])
        XCTAssertEqual(hits, 0, "a fresh disk hit must never call the network")
    }
}
