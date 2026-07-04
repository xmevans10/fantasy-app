import SwiftUI

struct SportFilterBar: View {
    @Binding var selection: SportFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SportFilter.allCases) { filter in
                    PrimeChip(label: filter.title, active: filter == selection) {
                        withAnimation(Motion.snap) { selection = filter }
                    }
                }
            }
        }
    }
}
