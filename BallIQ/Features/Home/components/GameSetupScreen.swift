import SwiftUI

/// Shared pre-game setup scaffold every format launches through (M18 follow-up: the Home
/// sport-filter chips are gone — sport is a per-game choice made here, right before play,
/// alongside each format's own options). One implementation so every format's setup screen
/// looks and behaves identically: format label, big title, SPORT picker with the same
/// Pro gating the old chips had, format-specific option cards, one big start button.
struct GameSetupScreen<Options: View>: View {
    @EnvironmentObject private var container: RepositoryContainer

    // `formatName` stays `String` — every call site is either a branded format name (kept
    // English, see Localizable.xcstrings) or `GameFormat`/local enum `.displayName`, a
    // runtime property access that can't literal-convert to LocalizedStringKey anyway.
    // `title`/`startLabel` are always call-site literals across all 4 setup screens, so
    // LocalizedStringKey lets them extract without touching those call sites.
    let formatName: String            // e.g. "DRAFT & SPIN"
    let title: LocalizedStringKey     // e.g. "Set your draft"
    let startLabel: LocalizedStringKey // e.g. "SPIN TO DRAFT"
    @Binding var sport: Sport
    let onStart: () -> Void
    let onClose: () -> Void
    /// Daily surfaces (Daily Draft) force the sport-of-the-day and stay playable regardless
    /// of the Pro sport gate — same rule as the daily Keep4/Who Am I?, which never route
    /// through a sport picker at all (product call, 2026-07-17). Exempts the Start guard and
    /// the locked-default snap-back for the forced sport only; *choosing* a locked sport is
    /// still Pro-gated.
    var sportGateExempt: Bool = false
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
                let filter = SportFilter(rawValue: sport.rawValue) ?? .all
                // The picker's own default can seed a Pro-locked sport (date-seeded "sport of
                // the day", or the last sport played before a Pro trial lapsed) without the
                // user ever tapping a locked chip — that path skips the picker's own lock
                // check entirely, so re-check here or Start would launch a real paid-tier
                // session for free.
                guard sportGateExempt || container.entitlements.canSelect(filter) else {
                    showPaywall = true; return
                }
                // Persist the choice as the app-wide default (rank widget, daily previews,
                // and the next setup screen all follow the last sport actually played) — but
                // never persist a sport the user couldn't select themselves: an exempt daily
                // launch on a locked-sport day must not flip the app-wide default to a Pro
                // sport.
                if container.entitlements.canSelect(filter) { container.sportFilter = filter }
                onStart()
            } label: {
                Text(startLabel)
                    .textCase(.uppercase)
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
        .onAppear { correctLockedDefault() }
        // Each format seeds `sport` asynchronously (last sport played / date-seeded "sport
        // of the day" / debug override) with no entitlement check, and that seeding often
        // lands *after* this screen's own `onAppear` already ran with the binding's initial
        // value — so re-check on every change too, or a locked sport that arrives late still
        // opens pre-selected as the active choice (confusing, and see the Start button's own
        // guard for why that state is more than just cosmetic).
        .onChange(of: sport) { _, _ in correctLockedDefault() }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(container)
        }
    }

    private func correctLockedDefault() {
        // An exempt screen's sport is forced externally (sport-of-the-day) and legitimately
        // allowed to be Pro-locked — snapping it to NFL would fight that forcing.
        guard !sportGateExempt else { return }
        let filter = SportFilter(rawValue: sport.rawValue) ?? .all
        if !container.entitlements.canSelect(filter) { sport = .nfl }
    }

    /// Concrete sports only (no "All" — a game session is always one sport), same Pro
    /// gating the old Home chips applied: locked sports show the lock and open the paywall.
    private var sportPicker: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                       GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Sport.allCases, id: \.self) { candidate in
                let filter = SportFilter(rawValue: candidate.rawValue) ?? .all
                // On an exempt screen the forced (active) sport plays for free today, so it
                // renders as a normal selection even when it'd otherwise be Pro-locked.
                let isLocked = !container.entitlements.canSelect(filter)
                    && !(sportGateExempt && candidate == sport)
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
    // LocalizedStringKey — every call site (this file's SPORT card, DraftSpinSetupView's 6)
    // passes a literal or a literal ternary/interpolation, so this extracts for free.
    let title: LocalizedStringKey
    let caption: LocalizedStringKey?
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
    // LocalizedStringKey so the 4 call sites' literal option arrays extract into
    // Localizable.xcstrings without themselves changing — see EmptyStateView for the
    // same pattern.
    let options: [LocalizedStringKey]
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
