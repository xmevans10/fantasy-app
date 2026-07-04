import SwiftUI

/// Prime Time search field — shared by Browse and Community (M13 text search).
/// Filtering is client-side and instant, so no debounce; the clear button resets in place.
struct PrimeSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.textMuted)
            TextField(placeholder, text: $text)
                .font(.body14)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// Collapsed icon ↔ expanded `PrimeSearchField` toggle — the search control for a
/// compact filter row (Browse/Community): a lone magnifying-glass button when idle,
/// expanding to a full search field + Cancel on tap so the row stays one line when not
/// actively searching (mirrors Mail's row-embedded search pattern).
struct PrimeExpandingSearch: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isExpanded: Bool

    var body: some View {
        if isExpanded {
            HStack(spacing: 8) {
                PrimeSearchField(placeholder: placeholder, text: $text)
                Button("Cancel") {
                    text = ""
                    withAnimation(Motion.snap) { isExpanded = false }
                }
                .font(.custom(FontName.condBold, size: 14))
                .foregroundStyle(Color.accentText)
            }
        } else {
            Button {
                withAnimation(Motion.snap) { isExpanded = true }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                    .padding(10)
                    .background(Color.surfaceMuted)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        }
    }
}
