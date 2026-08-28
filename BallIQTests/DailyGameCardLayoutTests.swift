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
/// Defect 2 was originally fixed by forcing every card to the same height (minTitleHeight,
/// ChipFlow minRows=2). That made cards ugly — extra whitespace inside a card whose title
/// was short or whose badges fit on one row. The fix (2026-07-29) moved height uniformity to
/// the section level via `DailyGamesPager.tallestPage`'s initial safe-zone floor, so cards
/// now size naturally and the pager stays stable.
///
/// These assert on *measured* geometry rather than on a screenshot, because a screenshot at the
/// wrong width is precisely how both defects survived review. PNGs are still written for
/// eyeballing — paths print as `DAILY_CARD:`. 
@MainActor
final class DailyGameCardLayoutTests: XCTestCase {

    /// The narrowest supported device (iPhone SE / 13 mini) and the reporter's iPhone 15 Pro.
    private let narrowWidths: [CGFloat] = [375, 393]

    /// Cards size to their content: a title that needs two lines makes a taller card than a
    /// one-line title. Asserted directionally rather than as "these two differ" — a bare
    /// inequality passes for any reason at all, including a layout bug that happens to change
    /// the number, and would fail spuriously the day two fixture titles measure the same.
    func testATwoLineTitleMakesATallerCardThanAOneLineTitle() throws {
        for width in narrowWidths {
            let short = try height(of: card(title: "Multi-homer games"), width: width)
            let long = try height(of: card(title: "Single-game triple-double explosions"), width: width)
            print("DAILY_CARD: @\(Int(width))pt short-title=\(short) long-title=\(long)")
            XCTAssertGreaterThan(long, short,
                "cards size to their content, per-card height inflation was removed because it "
                + "left empty bands inside light cards; the pager's own floor handles stability")
        }
    }

    /// The proof that chips **wrap** rather than clip. Under the old horizontal `ScrollView` the
    /// row was always exactly one row tall, so adding badges changed nothing about the card's
    /// height — they simply slid out of sight past the card's edge. A taller card for more
    /// badges is therefore the observable signature of them all being laid out on screen.
    func testMoreChipsMakeATallerCardBecauseTheyWrap() throws {
        for width in narrowWidths {
            let few = try height(of: card(title: "Multi-homer games", chips: .few), width: width)
            let many = try height(of: card(title: "Multi-homer games", chips: .many), width: width)
            print("DAILY_CARD: @\(Int(width))pt few-chips=\(few) many-chips=\(many)")
            XCTAssertGreaterThan(many, few,
                "six badges must occupy more rows than three at \(Int(width))pt, equal heights "
                + "would mean the overflow is being hidden again rather than wrapped")
        }
    }

    /// A title long enough to need three lines must render in full — cards should never
    /// truncate or cap title content.
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
