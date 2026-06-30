import SwiftUI

struct SportFilterBar: View {
    @Binding var selection: SportFilter

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SportFilter.allCases) { filter in
                let isActive = filter == selection
                Button {
                    withAnimation(Motion.snap) { selection = filter }
                } label: {
                    Text(filter.title.uppercased())
                        .font(.custom(isActive ? FontName.condBlack : FontName.condBold, size: 15))
                        .foregroundStyle(isActive ? Color.onAccent : Color.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(isActive ? Color.accentFill : Color.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
