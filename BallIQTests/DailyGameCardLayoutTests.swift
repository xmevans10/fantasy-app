import XCTest
import SwiftUI
@testable import BallIQ

/// Layout cover for `DailyGameCard` at the widths where it actually breaks.
///
/// Two defects reported from a device recording on 2026-07-29, both invisible at the 402pt
/// simulator width everything had been checked at:
///
/// 1. The header badge row was a horizontal `ScrollView`, so on a 393pt iPhone the "RANKED"
///    chip rendered as "RANKI" — sliced flat by the card edge, with no affordance suggesting
///    it scrolled. Replaced by `ChipFlow`, which wraps.
/// 2. Cards were different heights across sports, so the daily-games pager (whose cross-axis
///    size comes from its content) resized on every swipe and the entire "Your rank" section
///    below it jumped.
///
/// These assert on *measured* geometry rather than on a screenshot, because a screenshot at the
/// wrong width is precisely how both defects survived review. PNGs are still written for
/// eyeballing — paths print as `DAILY_CARD:`.
@MainActor
final class DailyGameCardLayoutTests: XCTestCase {

    /// The narrowest supported device (iPhone SE / 13 mini) and the reporter's iPhone 15 Pro.
    private let narrowWidths: [CGFloat] = [375, 393]

    /// Two cards whose titles wrap to a different number of lines must still be the same
    /// height, or the pager resizes when you swipe between the sports that own them.
    func testCardHeightIsIndependentOfTitleWrapping() throws {
        for width in narrowWidths {
            let short = try height(of: card(title: "Multi-homer games"), width: width)
            let long = try height(of: card(title: "Single-game triple-double explosions"), width: width)
            print("DAILY_CARD: @\(Int(width))pt short-title=\(short) long-title=\(long)")
            XCTAssertEqual(short, long, accuracy: 0.5,
                "a one-line title and a two-line title must produce the same card height — "
                + "otherwise swiping the pager between those sports moves everything below it")
        }
    }

    /// The chip count differs by format (Keep4 carries scoring + grain badges, Who Am I?
    /// doesn't), and wrapping means more chips can mean more rows. If that changes the card
    /// height it reintroduces the pager shift through a different door.
    func testCardHeightIsIndependentOfChipCount() throws {
        for width in narrowWidths {
            let few = try height(of: card(title: "Multi-homer games", chips: .few), width: width)
            let many = try height(of: card(title: "Multi-homer games", chips: .many), width: width)
            print("DAILY_CARD: @\(Int(width))pt few-chips=\(few) many-chips=\(many)")
            XCTAssertEqual(few, many, accuracy: 0.5,
                "a 3-chip Who Am I? card and a 6-chip Keep4 card must be the same height")
        }
    }

    /// A title long enough to need three lines must render in full. Reserving a minimum height
    /// is fine; capping it is not — that trades a layout wobble for lost content.
    func testAVeryLongTitleIsNotTruncated() throws {
        let width: CGFloat = 375
        let twoLine = try height(of: card(title: "Single-game triple-double explosions"), width: width)
        let veryLong = try height(of: card(
            title: "Single-game triple-double explosions across every qualifying postseason run"),
            width: width)
        print("DAILY_CARD: @375pt two-line=\(twoLine) very-long=\(veryLong)")
        XCTAssertGreaterThan(veryLong, twoLine,
            "a title needing more lines must grow the card, not be clipped to a fixed height")
    }

    /// Renders the worst-case loadout for visual inspection at both narrow widths.
    func testRenderNarrowWidthsForInspection() async throws {
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first,
            "no window in hosted test app")
        for width in narrowWidths {
            try await render(card(title: "Single-game triple-double explosions", chips: .many),
                             width: width, window: window,
                             filename: "daily_card_\(Int(width)).png")
            try await render(card(title: "Multi-homer games", chips: .few),
                             width: width, window: window,
                             filename: "daily_card_short_\(Int(width)).png")
        }
    }

    // MARK: - Fixtures

    private enum ChipLoad { case few, many }

    private func card(title: String, chips: ChipLoad = .many) -> some View {
        DailyGameCard(formatName: chips == .many ? "K4C4" : "Who am I?",
                      symbol: "rectangle.stack.fill",
                      sport: .nfl,
                      title: title,
                      subtitle: "8 games",
                      scoring: chips == .many ? .era : nil,
                      grain: chips == .many ? .career : nil,
                      completed: false,
                      favoriteTeamMatch: chips == .many,
                      ranked: true,
                      dateBadge: DailyGameCard.todayDateBadge) {}
    }

    // MARK: - Measurement

    private func height<V: View>(of card: V, width: CGFloat) throws -> CGFloat {
        let host = UIHostingController(rootView: card.frame(width: width))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func render<V: View>(_ card: V, width: CGFloat, window: UIWindow,
                                 filename: String) async throws {
        let framed = card.padding(16).frame(width: width).background(Color.appBackground)
        let host = UIHostingController(rootView: framed)
        let previous = window.rootViewController
        window.rootViewController = host
        defer { window.rootViewController = previous }

        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        host.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        window.layoutIfNeeded()
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try XCTUnwrap(image.pngData()).write(to: url)
        print("DAILY_CARD: \(url.path)")
    }
}
