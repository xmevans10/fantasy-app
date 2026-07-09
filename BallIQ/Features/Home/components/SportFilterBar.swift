import SwiftUI

struct SportFilterBar: View {
    @Binding var selection: SportFilter
    /// Marks a filter as Pro-locked (shows a lock glyph). Selecting one still routes through
    /// `selection`'s own binding — callers that gate access wrap it (see `HomeView`).
    var locked: (SportFilter) -> Bool = { _ in false }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SportFilter.allCases) { filter in
                    PrimeChip(label: filter.title, active: filter == selection,
                              systemImage: locked(filter) ? "lock.fill" : nil) {
                        withAnimation(Motion.snap) { selection = filter }
                    }
                }
            }
        }
    }
}
