import SwiftUI

/// Shared pre-game setup scaffold every format launches through (M18 follow-up: the Home
/// sport-filter chips are gone — sport is a per-game choice made here, right before play,
/// alongside each format's own options). One implementation so every format's setup screen
/// looks and behaves identically: format label, big title, SPORT picker with the same
/// Pro gating the old chips had, format-specific option cards, one big start button.
struct GameSetupScreen<Options: View>: View {
    @EnvironmentObject private var container: RepositoryContainer

    let formatName: String            // e.g. "DRAFT & SPIN"
    let title: String                 // e.g. "Set your draft"
    let startLabel: String            // e.g. "SPIN TO DRAFT"
    @Binding var sport: Sport
    let onStart: () -> Void
    let onClose: () -> Void
    @ViewBuilder var options: () -> Options

    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16)

            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text(formatName.uppercased()).font(.label12).foregroundStyle(Color.accentText)
                        Text(title).font(.title).foregroundStyle(Color.textPrimary)
                    }
                    .padding(.top, 8)

                    SetupOptionCard(title: "SPORT", caption: nil) {
                        sportPicker
                    }

                    options()
                }
                .padding(16)
            }

            Button {
                // Persist the choice as the app-wide default (rank widget, daily previews,
                // and the next setup screen all follow the last sport actually played).
                container.sportFilter = SportFilter(rawValue: sport.rawValue) ?? .all
                onStart()
            } label: {
                Text(startLabel.uppercased())
                    .font(.custom(FontName.condBlack, size: 18))
                    .foregroundStyle(Color.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PrimePressStyle())
            .padding(16)
        }
        .background(Color.appBackground)
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(container)
        }
    }

    /// Concrete sports only (no "All" — a game session is always one sport), same Pro
    /// gating the old Home chips applied: locked sports show the lock and open the paywall.
    private var sportPicker: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                       GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Sport.allCases, id: \.self) { candidate in
                let filter = SportFilter(rawValue: candidate.rawValue) ?? .all
                let isLocked = !container.entitlements.canSelect(filter)
                let active = sport == candidate
                Button {
                    if isLocked { showPaywall = true }
                    else { withAnimation(Motion.snap) { sport = candidate } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isLocked ? "lock.fill" : candidate.symbol)
                            .font(.system(size: 11, weight: .bold))
                        Text(candidate.displayName)
                            .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 13))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(active ? Color.onAccent : (isLocked ? Color.textMuted : Color.textPrimary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(active ? Color.accentFill : Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(isLocked ? 0.6 : 1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One titled option block on a setup screen — shared by every format so option rows
/// render identically everywhere.
struct SetupOptionCard<Control: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.label12).foregroundStyle(Color.accentText)
            control()
            if let caption {
                Text(caption).font(.label11).foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// Two-to-three-way segmented choice used inside `SetupOptionCard`s. `enabled` lets a
/// setup screen show an honest disabled option (e.g. NFL "Both sides" with no defensive
/// data) without hiding that the reference feature exists.
struct SetupSegmentedControl: View {
    let options: [String]
    let selectedIndex: Int
    var enabled: [Bool]? = nil
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                let active = i == selectedIndex
                let isEnabled = enabled?[i] ?? true
                Button {
                    guard isEnabled else { return }
                    onSelect(i)
                } label: {
                    Text(options[i])
                        .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 13))
                        .foregroundStyle(active ? Color.onAccent
                                         : (isEnabled ? Color.textPrimary : Color.textMuted))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(active ? Color.accentFill : Color.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .opacity(isEnabled ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
        }
    }
}
