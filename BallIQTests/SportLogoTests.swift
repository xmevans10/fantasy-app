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

    func testSharedCityCodeResolvesToTheCorrectLeague() {
        // "HOU" exists in NFL, NBA and MLB — each must resolve within its own league.
        XCTAssertEqual(Sport.nfl.teamLogoURL(forAbbr: "HOU")?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/nfl/500/hou.png")
        XCTAssertEqual(Sport.nba.teamLogoURL(forAbbr: "HOU")?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/nba/500/hou.png")
        XCTAssertEqual(Sport.baseball.teamLogoURL(forAbbr: "HOU")?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/mlb/500/hou.png")
    }

    func testSoccerAbbreviationTranslatesToESPNNumericID() {
        // ESPN keys soccer crests by numeric id, not the club abbreviation.
        XCTAssertEqual(Sport.soccer.teamLogoURL(forAbbr: "RMA")?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/soccer/500/86.png")
        XCTAssertEqual(Sport.soccer.teamLogoURL(forAbbr: "LIV")?.absoluteString,
                       "https://a.espncdn.com/i/teamlogos/soccer/500/364.png")
    }

    func testNilForEmptyOrUnmappedOrTeamless() {
        XCTAssertNil(Sport.baseball.teamLogoURL(forAbbr: ""))       // empty abbr
        XCTAssertNil(Sport.soccer.teamLogoURL(forAbbr: "ZZZ"))      // unmapped club
        XCTAssertNil(Sport.tennis.teamLogoURL(forAbbr: "ESP"))      // teamless sport
    }
}
