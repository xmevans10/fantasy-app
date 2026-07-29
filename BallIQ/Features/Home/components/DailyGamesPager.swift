import SwiftUI

/// Horizontal swipe pager across every sport's daily-games page on Home (2026-07-20). Browsing
/// only — the caller owns `selection` and decides whether/when to move it; this view never
/// reaches into `RepositoryContainer` itself, matching the "views read the container, not each
/// other's state" rule.
///
/// Built on the iOS 17 paging-`ScrollView` idiom (`scrollTargetBehavior(.paging)` +
/// `scrollPosition(id:)`) rather than `TabView(.page)`: a `TabView` given an explicit
/// `.frame(height:)` proposes that same height back down to every page, so a page measuring
/// its own height via `GeometryReader` just echoes the constraint back — a circular fixed
/// point that can never grow to fit real content. A horizontal `ScrollView` has no such loop:
/// it naturally reports its cross-axis (vertical) size from its content, so the two-card
/// stack's real height (which varies with theme-title wrapping, badges, etc.) just works.
struct DailyGamesPager<Page: View>: View {
    let sports: [Sport]
    @Binding var selection: Sport
    @ViewBuilder let page: (Sport) -> Page

    /// Tallest page measured so far, used as a floor for every page.
    ///
    /// The cross-axis freedom described above has a cost the original version paid in full:
    /// pages are genuinely different heights (a theme title that wraps to two lines, an extra
    /// badge row, a description), so the scroll view's own height changed on every swipe and
    /// **everything below the pager — the whole "Your rank" section and the rows under it —
    /// jumped up and down as the user browsed sports.** Reported from a device recording
    /// 2026-07-29.
    ///
    /// Holding the max rather than the current page's height means a swipe can only ever
    /// reveal whitespace under a shorter page, never reflow the page around it. It's a floor,
    /// not a fixed height, so a page taller than anything seen so far still grows — and
    /// because it only ever increases, it can't oscillate.
    @State private var tallestPage: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(sports) { sport in
                        page(sport)
                            // One page = exactly the scroll viewport's width, so a swipe
                            // always lands on a whole sport's pair, never a partial peek.
                            .containerRelativeFrame(.horizontal)
                            // Measured BEFORE the frame below is applied, so this reports the
                            // page's natural height. Measuring after would just echo back the
                            // height we imposed — the same circular fixed point that ruled out
                            // `TabView(.page)` in the first place.
                            .background(heightProbe)
                            .frame(minHeight: tallestPage > 0 ? tallestPage : nil, alignment: .top)
                            .id(sport)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: scrollBinding)
            .scrollIndicators(.hidden)
            .onPreferenceChange(PageHeightKey.self) { height in
                // Lazy pages are realized as they scroll in, so the floor settles over the
                // first pass through the sports rather than being known up front.
                if height > tallestPage { tallestPage = height }
            }

            indicator
        }
    }

    private var heightProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PageHeightKey.self, value: proxy.size.height)
        }
    }

    /// Bridges `selection: Binding<Sport>` to the `Binding<Sport?>` shape
    /// `scrollPosition(id:)` requires — bidirectional, so an external write to `selection`
    /// (Home landing the pager on the last-played sport) scrolls the view too, not just a
    /// user swipe writing back out.
    private var scrollBinding: Binding<Sport?> {
        Binding(get: { selection }, set: { if let sport = $0 { selection = sport } })
    }

    /// Dots instead of the system page style's translucent default, which reads as barely-there
    /// against the daily cards' own bold sport-colored header bands — the active dot borrows
    /// that same `cardFill` so the indicator visually agrees with the page it's pointing at.
    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(sports) { sport in
                let active = sport == selection
                Capsule()
                    .fill(active ? sport.cardFill : Color.borderInk.opacity(0.25))
                    .frame(width: active ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
        .accessibilityHidden(true)   // the cards' own content already announces the sport
    }
}

/// Max rather than "last one wins": several pages are realized at once while a swipe is in
/// flight, and the reduce has to settle on the tallest of them, not on whichever reported last.
private struct PageHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
