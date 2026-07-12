import XCTest
@testable import BallIQ

/// `LeaguesView.friendsLeaderboard` (M20) — merges the caller's own row with every accepted
/// friend's `PublicProfile`, ranks by a selected sport's rating (desc), and stably breaks
/// ties by username. Pure, so tested directly against literal `PublicProfile`/
/// `FriendsLeaderboardRow` values rather than through `SocialRepository`/network.
final class FriendsLeaderboardTests: XCTestCase {
    private func profile(_ id: String, username: String?, rating: Int, sport: Sport = .nfl) -> PublicProfile {
        PublicProfile(id: id, username: username, avatar: nil, streak: 0, xp: 0, ratings: [sport.rawValue: rating])
    }

    private func me(rating: Int, username: String? = "me") -> LeaguesView.FriendsLeaderboardRow {
        LeaguesView.FriendsLeaderboardRow(userID: "me-uuid", username: username, avatar: nil, rating: rating, isMe: true)
    }

    func testRanksByRatingDescendingAndIncludesMe() {
        let friends = [
            profile("a", username: "alpha", rating: 1200),
            profile("b", username: "bravo", rating: 900),
        ]

        let result = LeaguesView.friendsLeaderboard(me: me(rating: 1050), friends: friends, sport: .nfl)

        XCTAssertEqual(result.map(\.userID), ["a", "me-uuid", "b"])
        XCTAssertEqual(result.map(\.rating), [1200, 1050, 900])
    }

    func testRanksBySelectedSportNotSomeOtherSport() {
        let friends = [
            PublicProfile(id: "a", username: "alpha", avatar: nil, streak: 0, xp: 0,
                          ratings: [Sport.nfl.rawValue: 800, Sport.nba.rawValue: 1500]),
        ]

        let byNFL = LeaguesView.friendsLeaderboard(me: me(rating: 1000), friends: friends, sport: .nfl)
        let byNBA = LeaguesView.friendsLeaderboard(me: me(rating: 1000), friends: friends, sport: .nba)

        XCTAssertEqual(byNFL.map(\.userID), ["me-uuid", "a"])   // me (1000) beats a's NFL rating (800)
        XCTAssertEqual(byNBA.map(\.userID), ["a", "me-uuid"])   // a's NBA rating (1500) beats me (1000)
    }

    func testTiedRatingsBreakByUsernameAscendingCaseInsensitive() {
        let friends = [
            profile("z", username: "Zeta", rating: 1000),
            profile("a", username: "alpha", rating: 1000),
        ]

        let result = LeaguesView.friendsLeaderboard(me: me(rating: 1000, username: "Mike"), friends: friends, sport: .nfl)

        // Alphabetical (case-insensitive) at equal rating: alpha, Mike, Zeta.
        XCTAssertEqual(result.map(\.userID), ["a", "me-uuid", "z"])
    }

    func testMissingUsernamesSortAfterNamedPlayersAtTheSameRating() {
        let friends = [
            profile("noname", username: nil, rating: 1000),
            profile("named", username: "alpha", rating: 1000),
        ]

        let result = LeaguesView.friendsLeaderboard(me: me(rating: 1000, username: nil), friends: friends, sport: .nfl)

        XCTAssertEqual(result.first?.userID, "named")
        XCTAssertTrue(result.dropFirst().map(\.userID).contains("noname"))
        XCTAssertTrue(result.dropFirst().map(\.userID).contains("me-uuid"))
    }

    func testNoFriendsStillProducesJustMe() {
        let result = LeaguesView.friendsLeaderboard(me: me(rating: 1000), friends: [], sport: .nfl)
        XCTAssertEqual(result.map(\.userID), ["me-uuid"])
    }

    func testOnlyMeRowIsFlaggedIsMe() {
        let friends = [profile("a", username: "alpha", rating: 1200)]
        let result = LeaguesView.friendsLeaderboard(me: me(rating: 1000), friends: friends, sport: .nfl)
        XCTAssertEqual(result.filter(\.isMe).map(\.userID), ["me-uuid"])
    }
}
