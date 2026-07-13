import SwiftUI

/// The slot-machine moment, casino edition: a full-bleed layout (explicit feedback: no
/// dead space) — marquee lights top and bottom, a round header, and two **jumbo
/// full-width reels** (TEAM, YEAR) that roll through decoys with a rising haptic tick,
/// stop **staggered** (team first, year holding extra beats of anticipation), then land
/// with a volt glow pulse, an "IT'S A HIT" banner, a tilted "LOCKED IN" stamp and a
/// confetti burst. All Prime Time tokens (electric blue + volt, ink outlines,
/// Anton/Saira condensed); honors the screenshot flags by skipping straight to the
/// settled state, and Reduce Motion via `Celebrate`'s own particle opt-out.
struct SpinRevealView: View {
    let team: String
    let year: String
    /// e.g. "ROUND 2 OF 6" — fills the header so the spin stays anchored in the draft.
    var roundLabel: String = ""
    /// The final roster is fetched while the reels spin. The casino moment can settle even
    /// on a slow connection, but it does not advance to an empty draft board.
    @Binding var rosterReady: Bool
    let onFinished: () -> Void

    @State private var displayedTeam: String
    @State private var displayedYear: String
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
    private let totalTicks = 16
    private let staggerTicks = 5

    /// `realDecoyTeams`/`realDecoyYears`: actual in-sport values (drawn from the round's own
    /// broad sample pool) so the reel flashes plausible NFL teams/years for an NFL spin, NBA
    /// ones for an NBA spin, etc. — never another league's teams or an off-era year. Falls
    /// back to a cosmetic letter scramble only when the real pool is too thin to feel like a
    /// spin (e.g. a sport with barely any catalog coverage).
    init(team: String, year: String, roundLabel: String = "", realDecoyTeams: [String] = [],
         realDecoyYears: [String] = [], rosterReady: Binding<Bool> = .constant(true),
         onFinished: @escaping () -> Void) {
        self.team = team
        self.year = year
        self.roundLabel = roundLabel
        self._rosterReady = rosterReady
        self.onFinished = onFinished
        self.decoyTeams = Self.decoyPool(real: realDecoyTeams, answer: team)
        self.decoyYears = Self.decoyPool(real: realDecoyYears, answer: year)
        _displayedTeam = State(initialValue: team)
        _displayedYear = State(initialValue: year)
    }

    /// Prefers real values, excluding the answer itself so the reel never "spoils" by
    /// flashing the true team/year before it locks.
    private static func decoyPool(real: [String], answer: String) -> [String] {
        let distinct = Array(Set(real.filter { $0 != answer }))
        guard distinct.count >= 3 else { return decoys(for: answer) }
        return distinct
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
                reel(label: "TEAM", value: displayedTeam, locked: teamLocked)
                reel(label: "YEAR", value: displayedYear, locked: yearLocked)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)

            VStack(spacing: 14) {
                Text(settled ? "IT'S A HIT" : "SPINNING…")
                    .font(.custom(FontName.condBlack, size: 17))
                    .kerning(3)
                    .foregroundStyle(settled ? Color.voltText : Color.accentText)
                    .animation(Motion.snap, value: settled)
                if settled && !rosterReady {
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
        .onChange(of: rosterReady) { _, ready in
            if ready { finishIfReady() }
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
        guard !DebugLaunch.autoOpenDraftSpin else {
            displayedTeam = team; displayedYear = year
            teamLocked = true; yearLocked = true
            // `-screenshotDraftSpinReveal`: freeze here so the settled casino styling
            // (glow, marquee, LOCKED IN stamp) is what the screenshot captures.
            finishIfReady(delay: 0.05)
            return
        }
        if reduceMotion {
            displayedTeam = team; displayedYear = year
            teamLocked = true; yearLocked = true
            confetti += 1
            finishIfReady(delay: 0.05)
            return
        }
        tick(remaining: totalTicks + staggerTicks)
    }

    private func tick(remaining: Int) {
        // Team reel locks `staggerTicks` before the year reel — the anticipation beat.
        if !teamLocked && remaining <= staggerTicks {
            withAnimation(Motion.overshoot) { displayedTeam = team }
            teamLocked = true
            Haptics.commit()
        }
        guard remaining > 0 else {
            withAnimation(Motion.overshoot) { displayedYear = year }
            yearLocked = true
            confetti += 1
            Haptics.success()
            finishIfReady(delay: 1.0)
            return
        }
        // The roll animation stretches with the tick interval, so late (slow) ticks glide
        // instead of snapping at the same speed as the opening blur — the deceleration
        // reads in the motion, not just the timing.
        let elapsed = (totalTicks + staggerTicks) - remaining
        let delay = 0.05 + Double(elapsed) * 0.013
        withAnimation(.easeOut(duration: min(delay * 1.4, 0.22))) {
            if !teamLocked { displayedTeam = decoyTeams.randomElement() ?? team }
            displayedYear = decoyYears.randomElement() ?? year
        }
        // Whisper-quiet early ticks that firm up as the reels slow — a ramp on one warm
        // soft generator, not a uniform hammer of one-shot light impacts.
        let progress = Double(elapsed) / Double(totalTicks + staggerTicks)
        ticker.tick(intensity: 0.3 + 0.6 * progress)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tick(remaining: remaining - 1) }
    }

    /// A network miss never reveals an empty board. Conversely, a fast request does not skip
    /// the landing beat: the reel owns its full animation before this callback fires.
    private func finishIfReady(delay: Double = 0) {
        guard settled, rosterReady, !hasFinished, !DebugLaunch.holdDraftSpinReveal else { return }
        hasFinished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { onFinished() }
    }
}
