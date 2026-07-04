import XCTest
@testable import BallIQ

/// Pure filter-logic tests for the Browse decade facet — mirrors `CommunityFeedTests.swift`'s
/// style of testing a static function directly. (The position facet was removed as part of
/// decluttering Browse's filter row — see BrowseView's dropdown-row redesign.)
final class BrowseFiltersTests: XCTestCase {

    private func puzzle(theme: String, sport: Sport, years: [Int]) -> Keep4Puzzle {
        let players = years.enumerated().map { i, y in
            PlayerSeason(id: "p\(i)", name: "P\(i)", teamAbbr: "AAA", seasonYear: y,
                        stats: [], grade: 0)
        }
        return Keep4Puzzle(id: "t", theme: theme, sport: sport, players: players)
    }

    func testDecadeBucketsByMedianYear() {
        let p = puzzle(theme: "x", sport: .nfl, years: [2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018])
        XCTAssertEqual(BrowseFilters.decade(of: p), .twentyTens)
    }

    func testDecadeFilterAllMatchesEverything() {
        let p = puzzle(theme: "x", sport: .nfl, years: [1999, 2000, 2001, 2002, 2003, 2004, 2005, 2006])
        XCTAssertTrue(BrowseFilters.matchesDecade(p, filter: .all))
    }

    func testDecadeFilterOnlyMatchesItsOwnBucket() {
        let p = puzzle(theme: "x", sport: .nfl, years: Array(repeating: 2015, count: 8))
        XCTAssertTrue(BrowseFilters.matchesDecade(p, filter: .twentyTens))
        XCTAssertFalse(BrowseFilters.matchesDecade(p, filter: .twentyTwenties))
    }

}
