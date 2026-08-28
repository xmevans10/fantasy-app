import XCTest
@testable import BallIQ

/// Guards the per-sport ESPN team-logo resolution. Regression test for the bug where every
/// non-NFL sport shared the "nba" league slug, so shared city codes pulled the wrong league's
/// crest (MLB "HOU" → the NBA Rockets instead of the Astros).
final class SportLogoTests: XCTestCase {

    func testEachTeamedSportUsesItsOwnLeagueSlug() {
        XCTAssertEqual(Sport.nfl.espnLeagueSlug, "nfl")
        XCTAssertEqual(Sport.nba.espnLeagueSlug, "nba")
        XCTAssertEqual(Sport.baseball.espnLeagueSlug, "mlb")
        XCTAssertEqual(Sport.soccer.espnLeagueSlug, "soccer")
        XCTAssertNil(Sport.tennis.espnLeagueSlug)   // teamless — country flag, no team logo
    }

    // These assert the LEGACY ESPN-CDN fallback specifically, so each passes a fresh empty
    // `TeamIdentityIndex` — with no fetched `teams` data loaded, `teamLogoURL` must fall
    // through to the hardcoded ESPN resolution. Injecting an empty index keeps the assertions
    // deterministic regardless of what the process-wide `.shared` index holds (other tests, or
    // a real fetch, may have populated it with rehosted Storage URLs).
    private let emptyIndex = TeamIdentityIndex()

    /// "HOU" exists in NFL, NBA and MLB — each must resolve within its own league.
    ///
    /// Asserted on the resolved *identity* rather than a literal CDN URL since crests are bundled
    /// (2026-08-28): each sport now answers with its own `crest-<sport>-...` file. The property
    /// under test was never the hostname, it was that one code doesn't leak across sports.
    func testSharedCityCodeResolvesToTheCorrectLeague() {
        let resolved: [(Sport, String)] = [(.nfl, "nfl"), (.nba, "nba"), (.baseball, "baseball")]
        var seen: Set<String> = []
        for (sport, token) in resolved {
            let url = sport.teamLogoURL(forAbbr: "HOU", index: emptyIndex)?.absoluteString ?? ""
            XCTAssertTrue(url.contains(token), "\(sport.rawValue) resolved to \(url)")
            XCTAssertTrue(seen.insert(url).inserted, "two sports share one crest URL: \(url)")
        }
    }

    /// A sport with no bundled crest for the code still reaches the ESPN fallback, so the
    /// legacy path stays exercised rather than silently dead.
    func testUnbundledCodeStillFallsBackToESPN() {
        let url = Sport.nfl.teamLogoURL(forAbbr: "ZZZ", index: emptyIndex)?.absoluteString
        XCTAssertEqual(url, "https://a.espncdn.com/i/teamlogos/nfl/500/zzz.png")
    }

    func testSoccerAbbreviationTranslatesToESPNNumericID() {
        // ESPN keys soccer crests by numeric id, not the club abbreviation.
        XCTAssertEqual(Sport.soccer.teamLogoURL(forAbbr: "RMA", index: emptyIndex)?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/soccer/500/86.png")
        XCTAssertEqual(Sport.soccer.teamLogoURL(forAbbr: "LIV", index: emptyIndex)?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/soccer/500/364.png")
    }

    func testNilForEmptyOrUnmappedOrTeamless() {
        XCTAssertNil(Sport.baseball.teamLogoURL(forAbbr: "", index: emptyIndex))    // empty abbr
        XCTAssertNil(Sport.soccer.teamLogoURL(forAbbr: "ZZZ", index: emptyIndex))   // unmapped club
        XCTAssertNil(Sport.tennis.teamLogoURL(forAbbr: "ESP", index: emptyIndex))   // teamless sport
    }
}
