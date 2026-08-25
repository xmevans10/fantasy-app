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
    /// Optional second way out of this screen, rendered under the start button (The Grid's
    /// "new random grid"). Routed through the *same* entitlement guard and sport-persistence
    /// as Start rather than getting its own copy — a second copy is exactly how one of the two
    /// ends up drifting into launching a Pro session for free.
    var secondaryLabel: LocalizedStringKey? = nil
    var onSecondary: (() -> Void)? = nil
    /// **Multi-sport mode** (Puzzle Blitz, the one format whose session spans sports). When
    /// non-nil the SPORT card becomes a multi-select over this set, and `sport` follows the
    /// first-ordered selection so everything else on this screen — the entitlement guard, the
    /// app-wide sport-default write, the team-identity warm — keeps working unchanged rather
    /// than growing a parallel multi-sport copy of itself.
    ///
    /// Added here rather than by writing Blitz its own setup screen because this scaffold is the
    /// promise that every format's setup "looks and behaves identically" (see this type's own doc
    /// comment); a second screen is how the two drift, and the Pro gate is exactly the thing that
    /// must not drift. Defaulted to nil, so the four existing call sites are untouched.
    var sports: Binding<Set<Sport>>? = nil
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

                    // "SPORTS" (plural) in multi-select mode — the card title is the only thing
                    // on screen that says whether ticking a second chip replaces the first or
                    // adds to it.
                    SetupOptionCard(title: sports == nil ? "SPORT" : "SPORTS", caption: nil) {
                        sportPicker
                    }

                    options()
                }
                .padding(16)
            }

            VStack(spacing: 10) {
                Button {
                    begin(onStart)
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

                if let secondaryLabel, let onSecondary {
                    Button {
                        begin(onSecondary)
                    } label: {
                        Text(secondaryLabel)
                            .textCase(.uppercase)
                            .font(.custom(FontName.condBold, size: 15))
                            .foregroundStyle(Color.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PrimePressStyle())
                }
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .onAppear { correctLockedDefault(); warmTeamIdentities() }
        // Each format seeds `sport` asynchronously (last sport played / date-seeded "sport
        // of the day" / debug override) with no entitlement check, and that seeding often
        // lands *after* this screen's own `onAppear` already ran with the binding's initial
        // value — so re-check on every change too, or a locked sport that arrives late still
        // opens pre-selected as the active choice (confusing, and see the Start button's own
        // guard for why that state is more than just cosmetic).
        .onChange(of: sport) { _, _ in correctLockedDefault(); warmTeamIdentities() }
        // Both of this screen's paywall routes — the locked-chip tap and the Start-button
        // entitlement guard — are the same surface (a Pro sport the user tried to play), so
        // the trigger is fixed here rather than carried in state.
        .sheet(isPresented: $showPaywall) {
            PaywallView(trigger: .sportPicker).environmentObject(container)
        }
    }

    /// The entitlement guard + sport persistence every way off this screen shares. Both the
    /// start button and the optional secondary action run through here so neither can drift
    /// into launching a Pro-tier session for free.
    private func begin(_ action: () -> Void) {
        let filter = SportFilter(rawValue: sport.rawValue) ?? .all
        // In multi-sport mode EVERY selected sport has to clear the gate, not just the primary
        // one `sport` tracks — otherwise ticking NFL plus a Pro sport would launch a session
        // that serves the locked sport's boards for free, which is the same hole the
        // single-sport guard below exists to close.
        if let sports {
            guard !sports.wrappedValue.isEmpty else { return }
            let locked = sports.wrappedValue.contains {
                !container.entitlements.canSelect(SportFilter(rawValue: $0.rawValue) ?? .all)
            }
            guard sportGateExempt || !locked else { showPaywall = true; return }
        }
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
        action()
    }

    /// Warms the team/league identity index for the sport about to be played. This screen is the
    /// one surface *every* format passes through immediately before rendering crests, so warming
    /// here covers all of them instead of each format remembering to do it.
    ///
    /// It was previously only warmed by `prefetchDraftSpinSample`, so a cold Grid open found an
    /// empty index, missed `teams.logo_url`, and fell through to `Sport.legacyTeamLogoURL` — the
    /// ESPN CDN, which serves `cache-control: max-age=123` (crests re-download every two
    /// minutes) and which for soccer only knows 11 hardcoded clubs, so nearly every club
    /// rendered no crest at all.
    private func warmTeamIdentities() {
        // Multi-sport mode warms every ticked sport, not just the primary: a blitz serves boards
        // from all of them, and an unwarmed sport is exactly the cold-index case this method's
        // history is about (an empty index falls through to the ESPN CDN, which for soccer knows
        // eleven clubs).
        for sport in sports?.wrappedValue ?? [sport] { container.catalog.warmIdentities(for: sport) }
    }

    private func correctLockedDefault() {
        // An exempt screen's sport is forced externally (sport-of-the-day) and legitimately
        // allowed to be Pro-locked — snapping it to NFL would fight that forcing.
        guard !sportGateExempt else { return }
        // Multi-sport mode: drop every locked sport from the persisted selection (a Pro trial
        // can lapse between runs, leaving a saved config full of sports this account can no
        // longer play) and never leave the set empty, which would disable Start with no
        // explanation. Then fall through so `sport` is re-derived from what survived.
        if let sports {
            let allowed = sports.wrappedValue.filter {
                container.entitlements.canSelect(SportFilter(rawValue: $0.rawValue) ?? .all)
            }
            let corrected = allowed.isEmpty ? Set([Sport.nfl]) : allowed
            if corrected != sports.wrappedValue { sports.wrappedValue = corrected }
            let primary = Sport.allCases.first(where: corrected.contains) ?? .nfl
            if sport != primary { sport = primary }
            return
        }
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
                // Multi-sport mode highlights every ticked sport, not just the primary.
                let active = sports.map { $0.wrappedValue.contains(candidate) } ?? (sport == candidate)
                Button {
                    if isLocked { showPaywall = true }
                    else if let sports { withAnimation(Motion.snap) { toggle(candidate, in: sports) } }
                    else { withAnimation(Motion.snap) { sport = candidate } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isLocked ? "lock.fill"
                              : (sports != nil && active ? "checkmark" : candidate.symbol))
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

    /// Ticks/unticks one sport in multi-sport mode, refusing to empty the set — an empty
    /// selection can't serve a board, and a Start button that silently does nothing is worse
    /// than a chip that won't untick. `sport` follows so the entitlement guard, the app-wide
    /// default write and the identity warm all keep reading one concrete sport.
    private func toggle(_ candidate: Sport, in sports: Binding<Set<Sport>>) {
        var next = sports.wrappedValue
        if next.contains(candidate) {
            guard next.count > 1 else { return }
            next.remove(candidate)
        } else {
            next.insert(candidate)
        }
        sports.wrappedValue = next
        sport = Sport.allCases.first(where: next.contains) ?? .nfl
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

/// Two-to-three-way segmented choice used inside `SetupOptionCard`s.
struct SetupSegmentedControl: View {
    // LocalizedStringKey so the 4 call sites' literal option arrays extract into
    // Localizable.xcstrings without themselves changing — see EmptyStateView for the
    // same pattern.
    let options: [LocalizedStringKey]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                let active = i == selectedIndex
                Button {
                    onSelect(i)
                } label: {
                    Text(options[i])
                        .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 13))
                        .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(active ? Color.accentFill : Color.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
