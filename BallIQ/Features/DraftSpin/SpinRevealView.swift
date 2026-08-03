import SwiftUI

/// The slot-machine moment, casino edition: a full-bleed layout (explicit feedback: no
/// dead space) — marquee lights top and bottom, a round header, and two **jumbo
/// full-width reels** (TEAM, YEAR) that roll through decoys with a rising haptic tick,
/// stop **staggered** (team first, year holding extra beats of anticipation), then land
/// with a volt glow pulse, an "IT'S A HIT" banner, a tilted "LOCKED IN" stamp and a
/// confetti burst. All Prime Time tokens (electric blue + volt, ink outlines,
/// Anton/Saira condensed); honors the screenshot flags by skipping straight to the
/// settled state, and Reduce Motion via `Celebrate`'s own particle opt-out.
/// The validated outcome of one spin. Optional at the reel's input because it genuinely isn't
/// known when the reel starts — see `SpinRevealView.target`.
struct SpinRevealTarget: Equatable {
    let team: String
    let year: String
}

struct SpinRevealView: View {
    /// The landed (team, year), or nil while `spinUntilFillable` is still fetching and validating
    /// a combo's roster. **The reel keeps rolling decoys until this arrives** and only then locks.
    ///
    /// This is the change that finally makes good on this view's original design intent. The
    /// `rosterReady` flag it replaces was documented as "the final roster is fetched while the
    /// reels spin", but a later fillability re-spin (the "BRO 2006" fix) moved the fetch *before*
    /// `presentRound` — so the flag was always true on arrival, the overlap never happened, and
    /// the fetch instead showed up as a dead frame before the reel started.
    ///
    /// It must be a `Binding`, not a plain `let`: the tick loop recurses through
    /// `DispatchQueue.main.asyncAfter`, whose closure captures a *copy* of this struct. A stale
    /// copy's `let` would never see a late value, whereas a Binding reads live parent state.
    @Binding var target: SpinRevealTarget?
    /// e.g. "ROUND 2 OF 6" — fills the header so the spin stays anchored in the draft.
    var roundLabel: String = ""
    let onFinished: () -> Void

    @State private var displayedTeam: String
    @State private var displayedYear: String
    /// Ticks spent waiting past the natural end of the reel for `target` to arrive. Capped so a
    /// never-arriving target (every candidate unfillable — the caller then navigates away) can't
    /// leave a scheduling loop running forever behind a dismissed view.
    @State private var extensions = 0
    private static let maxExtensions = 60
    @State private var teamLocked = false
    @State private var yearLocked = false
    @State private var confetti = 0
    @State private var lightsPhase = false
    @State private var hasFinished = false
    /// One warm generator for the whole reel run — see `HapticTicker` for why the
    /// one-shot `Haptics` helpers are wrong for a 20-tick sequence.
    private let ticker = HapticTicker()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let decoyTeams: [String]
    private let decoyYears: [String]

    /// Ticks before the FIRST reel locks; the second rolls `staggerTicks` beyond it.
    ///
    /// The full run is deliberately long — it's the signature casino moment. 21 ticks at
    /// `0.05 + 0.013 x elapsed` is 3.78s of reel plus the landing beat, ~4.8s a spin.
    ///
    /// **Both branches are live but only the full one is used** (`DraftSpinView`, 2026-08-01).
    /// History worth keeping, because this has flipped once and may again: the abbreviated branch
    /// was added when the repetition read as lag (a draft is 3–8 rounds, so 8-round soccer spent
    /// ~38s watching reels), then disabled on user report that the shortened later spins felt cut
    /// off rather than snappy. Shortening it is a one-word change at the call site; the whole-draft
    /// cost of *not* shortening it is asserted in `SpinRevealTimingTests` so it stays visible.
    ///
    /// Tuning knob: these four numbers are the whole dial.
    static func tickCounts(abbreviated: Bool) -> (total: Int, stagger: Int) {
        abbreviated ? (total: 7, stagger: 3) : (total: 16, stagger: 5)
    }

    /// Whether rounds after the first use the abbreviated run. Lives here rather than as a literal
    /// at the `DraftSpinView` call site so the pacing decision is single-sourced and *testable* —
    /// `SpinRevealTimingTests` asserts against this, which a literal `false` in a view body
    /// couldn't support.
    static let abbreviatesLaterRounds = false

    /// The roll animation stretches with the tick interval, so late (slow) ticks glide instead of
    /// snapping at the opening blur's speed — the deceleration reads in the motion, not just the
    /// timing.
    static func tickDelay(elapsed: Int) -> Double { 0.05 + Double(elapsed) * 0.013 }

    /// Wall-clock seconds of the reel run, excluding the landing beat. Pure and static purely so
    /// the time budget is *asserted* (`SpinRevealTimingTests`) rather than eyeballed — this is
    /// the number that decides whether a draft feels snappy or laggy, and it's easy to inflate
    /// by a second without noticing while tuning the feel of an individual tick.
    static func reelSeconds(abbreviated: Bool) -> Double {
        let counts = tickCounts(abbreviated: abbreviated)
        return (0..<(counts.total + counts.stagger)).reduce(0.0) { $0 + tickDelay(elapsed: $1) }
    }

    /// The "savor it" beat after the confetti fires, once both reels have locked.
    static func landingSeconds(abbreviated: Bool) -> Double { abbreviated ? 0.3 : 0.5 }

    static func totalSeconds(abbreviated: Bool) -> Double {
        reelSeconds(abbreviated: abbreviated) + landingSeconds(abbreviated: abbreviated)
    }

    private var totalTicks: Int { Self.tickCounts(abbreviated: abbreviated).total }
    private var staggerTicks: Int { Self.tickCounts(abbreviated: abbreviated).stagger }

    /// Set for every round after the first — see `totalTicks`.
    let abbreviated: Bool

    /// `realDecoyTeams`/`realDecoyYears`: actual in-sport values (drawn from the round's own
    /// broad sample pool) so the reel flashes plausible NFL teams/years for an NFL spin, NBA
    /// ones for an NBA spin, etc. — never another league's teams or an off-era year. Falls
    /// back to a cosmetic letter scramble only when the real pool is too thin to feel like a
    /// spin (e.g. a sport with barely any catalog coverage).
    init(target: Binding<SpinRevealTarget?>, roundLabel: String = "",
         realDecoyTeams: [String] = [], realDecoyYears: [String] = [],
         abbreviated: Bool = false,
         onFinished: @escaping () -> Void) {
        self._target = target
        self.roundLabel = roundLabel
        self.abbreviated = abbreviated
        self.onFinished = onFinished
        self.decoyTeams = Self.decoyPool(real: realDecoyTeams, sample: target.wrappedValue?.team)
        self.decoyYears = Self.decoyPool(real: realDecoyYears, sample: target.wrappedValue?.year)
        _displayedTeam = State(initialValue: Self.decoyTeams(realDecoyTeams, sample: target.wrappedValue?.team).first ?? "—")
        _displayedYear = State(initialValue: Self.decoyTeams(realDecoyYears, sample: target.wrappedValue?.year).first ?? "—")
    }

    /// Prefers real values for the decoy pool. The answer is filtered out **at tick time**
    /// (`nextDecoy`) rather than here, because when the reel starts there may not be an answer
    /// yet — that's the whole point of a late `target`.
    ///
    /// `sample` is only used to size the cosmetic fallback scramble, so a nil target just means
    /// a generic-width placeholder until real decoys are available.
    private static func decoyPool(real: [String], sample: String?) -> [String] {
        decoyTeams(real, sample: sample)
    }

    private static func decoyTeams(_ real: [String], sample: String?) -> [String] {
        let distinct = Array(Set(real))
        guard distinct.count >= 3 else { return decoys(for: sample ?? "···") }
        return distinct.sorted()
    }

    /// A decoy that is never the landed answer — preserves the "the reel must not spoil the
    /// result before it locks" property from the moment the answer is actually known.
    private func nextDecoy(from pool: [String], avoiding answer: String?) -> String? {
        pool.filter { $0 != answer }.randomElement() ?? pool.randomElement()
    }

    /// Cosmetic-only scramble of the real code's letters — always renders a legible,
    /// same-length placeholder, no dependency on a full team-name/year catalog.
    private static func decoys(for text: String) -> [String] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let length = max(text.count, 2)
        return (0..<10).map { _ in String((0..<length).map { _ in letters.randomElement() ?? "X" }) }
    }

    private var settled: Bool { teamLocked && yearLocked }

    var body: some View {
        VStack(spacing: 0) {
            marqueeLights.padding(.top, 18)

            VStack(spacing: 4) {
                Text("DRAFT & SPIN").font(.label12).kerning(2).foregroundStyle(Color.accentText)
                if !roundLabel.isEmpty {
                    Text(roundLabel.uppercased())
                        .font(.custom(FontName.condBlack, size: 22))
                        .foregroundStyle(Color.textPrimary)
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 12)

            VStack(spacing: 16) {
                reel(label: String(localized: "TEAM"), value: displayedTeam, locked: teamLocked)
                reel(label: String(localized: "YEAR"), value: displayedYear, locked: yearLocked)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)

            VStack(spacing: 14) {
                Text(settled ? "IT'S A HIT" : "SPINNING…")
                    .font(.custom(FontName.condBlack, size: 17))
                    .kerning(3)
                    .foregroundStyle(settled ? Color.voltText : Color.accentText)
                    .animation(Motion.snap, value: settled)
                // Only once the wait has outlasted the reel itself. A typical fetch (~0.4s)
                // finishes long before the reels would have stopped anyway, and announcing it
                // every single round would be flicker that undercuts the casino illusion for no
                // information gain — the reels spinning already says "wait a moment".
                if target == nil, extensions > 0 {
                    Text("SCOUTING THE ROSTER…")
                        .font(.label11).foregroundStyle(Color.textMuted)
                }
                Text("LOCKED IN")
                    .font(.custom(FontName.condBlack, size: 24))
                    .kerning(3)
                    .foregroundStyle(Color.onVolt)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Color.voltFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.borderInk, lineWidth: 3))
                    .rotationEffect(.degrees(settled ? -4 : -14))
                    .scaleEffect(settled ? 1 : 0.3)
                    .opacity(settled ? 1 : 0)
                    .animation(Motion.overshoot, value: settled)
            }

            Spacer(minLength: 12)

            marqueeLights.padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: 60)
        .onAppear {
            ticker.prepare()   // wake the Taptic Engine before the first tick, not on it
            withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                lightsPhase = true
            }
            spin()
        }
        // The reduce-motion / screenshot paths bail out of `spin()` when the target hasn't landed
        // yet; this is what settles them once it does.
        .onChange(of: target) { _, landed in
            guard let landed, DebugLaunch.autoOpenDraftSpin || reduceMotion else { return }
            settleImmediately(to: landed, celebrate: !DebugLaunch.autoOpenDraftSpin)
        }
    }

    /// A casino-sign row of chasing lights: alternating blue/volt bulbs blinking in
    /// counter-phase while the reels roll, all steady-on volt once the spin settles.
    private var marqueeLights: some View {
        HStack(spacing: 0) {
            ForEach(0..<13, id: \.self) { i in
                Circle()
                    .fill(settled ? Color.voltFill : (i.isMultiple(of: 2) ? Color.accentFill : Color.voltFill))
                    .frame(width: 11, height: 11)
                    .opacity(settled ? 1 : (i.isMultiple(of: 2) == lightsPhase ? 1 : 0.25))
                    .shadow(color: (settled || i.isMultiple(of: 2) == lightsPhase)
                            ? Color.voltFill.opacity(0.8) : .clear, radius: 5)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 28)
        .animation(Motion.snap, value: settled)
    }

    /// One jumbo full-width reel — the screen's centerpiece, not a small chip.
    private func reel(label: String, value: String, locked: Bool) -> some View {
        VStack(spacing: 10) {
            Text(label).font(.custom(FontName.condBold, size: 14)).kerning(2.5)
                .foregroundStyle(locked ? Color.voltText : Color.textMuted)
            Text(value.uppercased())
                .font(.custom(FontName.condBlack, size: 64))
                .foregroundStyle(locked ? Color.textPrimary : Color.textMuted)
                .lineLimit(1).minimumScaleFactor(0.35)
                .id(value)   // new identity per tick so the roll transition fires
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(locked ? Color.voltFill : Color.borderInk, lineWidth: locked ? 4 : 3))
        .shadow(color: locked ? Color.voltFill.opacity(0.55) : .clear, radius: locked ? 16 : 0)
        .scaleEffect(locked ? 1.04 : 1.0)
        .animation(Motion.overshoot, value: locked)
    }

    private func spin() {
        // Both fast paths need a landed target to snap to; if it hasn't arrived yet they fall
        // through to the normal roll and `onChange(of: target)` settles them the moment it does.
        if DebugLaunch.autoOpenDraftSpin || reduceMotion, let target {
            settleImmediately(to: target, celebrate: !DebugLaunch.autoOpenDraftSpin)
            return
        }
        tick(remaining: totalTicks + staggerTicks)
    }

    /// `-screenshotDraftSpinReveal` freezes on the settled casino styling (glow, marquee, LOCKED
    /// IN stamp) rather than the roll; Reduce Motion skips the roll but keeps the payoff.
    private func settleImmediately(to target: SpinRevealTarget, celebrate: Bool) {
        guard !yearLocked else { return }
        displayedTeam = target.team
        displayedYear = target.year
        teamLocked = true
        yearLocked = true
        if celebrate { confetti += 1 }
        finishIfReady(delay: 0.05)
    }

    private func tick(remaining: Int) {
        // Reached the point where the team reel would lock, but nothing has landed yet: hold the
        // countdown AT that threshold rather than letting it run to zero.
        //
        // Holding at `staggerTicks` (not 0) is the load-bearing detail. Both locks are gated on a
        // landed target, so if the countdown were allowed to reach zero first, a late target would
        // satisfy the team-lock and year-lock conditions in the *same* tick — both reels snapping
        // together and throwing away the anticipation beat that gives the moment its shape.
        // Held here, a late target locks the team on the next tick and the year `staggerTicks`
        // after that, exactly as an on-time one does.
        let waiting = target == nil && remaining <= staggerTicks
        if waiting {
            extensions += 1
            guard extensions <= Self.maxExtensions else { return }
        }
        // Team reel locks `staggerTicks` before the year reel — the anticipation beat.
        if !teamLocked, remaining <= staggerTicks, let target {
            withAnimation(Motion.overshoot) { displayedTeam = target.team }
            teamLocked = true
            Haptics.commit()
        }
        if remaining <= 0, let target {
            withAnimation(Motion.overshoot) { displayedYear = target.year }
            yearLocked = true
            confetti += 1
            Haptics.success()
            // A full second here was generous for a once-per-game moment and simply dead time
            // once it repeats every round.
            finishIfReady(delay: Self.landingSeconds(abbreviated: abbreviated))
            return
        }
        let elapsed = (totalTicks + staggerTicks) - max(remaining, 0)
        let delay = Self.tickDelay(elapsed: elapsed)
        withAnimation(.easeOut(duration: min(delay * 1.4, 0.22))) {
            if !teamLocked, let decoy = nextDecoy(from: decoyTeams, avoiding: target?.team) {
                displayedTeam = decoy
            }
            if let decoy = nextDecoy(from: decoyYears, avoiding: target?.year) {
                displayedYear = decoy
            }
        }
        // Whisper-quiet early ticks that firm up as the reels slow — a ramp on one warm
        // soft generator, not a uniform hammer of one-shot light impacts.
        let progress = Double(elapsed) / Double(totalTicks + staggerTicks)
        ticker.tick(intensity: 0.3 + 0.6 * min(progress, 1))
        let next = waiting ? staggerTicks : max(remaining - 1, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tick(remaining: next) }
    }

    /// A network miss never reveals an empty board — `settled` can't be true without a landed
    /// `target`, which only exists once the roster is fetched AND vetted. Conversely, a fast
    /// request does not skip the landing beat: the reel owns its full animation before this fires.
    private func finishIfReady(delay: Double = 0) {
        guard settled, !hasFinished, !DebugLaunch.holdDraftSpinReveal else { return }
        hasFinished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { onFinished() }
    }
}
