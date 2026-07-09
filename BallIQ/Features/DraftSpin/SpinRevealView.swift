import SwiftUI

/// The slot-machine moment, casino edition: a marquee of chasing lights frames two big
/// blockCard reels (TEAM, YEAR) that roll through decoys with a rising haptic tick, stop
/// **staggered** — team first, year holding two extra beats of anticipation — then land
/// with a volt glow pulse, a "LOCKED IN" stamp and a confetti burst. All Prime Time
/// tokens (electric blue + volt, ink outlines, Anton/Saira condensed); honors the
/// screenshot flags by skipping straight to the settled state, and Reduce Motion by
/// letting `Celebrate` drop its particles.
struct SpinRevealView: View {
    let team: String
    let year: String
    let onFinished: () -> Void

    @State private var displayedTeam: String
    @State private var displayedYear: String
    @State private var teamLocked = false
    @State private var yearLocked = false
    @State private var confetti = 0
    @State private var lightsPhase = false

    private let decoyTeams: [String]
    private let decoyYears: [String]
    /// Ticks before the FIRST reel locks; the second rolls `staggerTicks` beyond it.
    private let totalTicks = 16
    private let staggerTicks = 5

    init(team: String, year: String, onFinished: @escaping () -> Void) {
        self.team = team
        self.year = year
        self.onFinished = onFinished
        self.decoyTeams = Self.decoys(for: team)
        self.decoyYears = Self.decoys(for: year)
        _displayedTeam = State(initialValue: team)
        _displayedYear = State(initialValue: year)
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
        VStack(spacing: 26) {
            marqueeLights
            Text(settled ? "IT'S A HIT" : "SPINNING…")
                .font(.custom(FontName.condBlack, size: 15))
                .kerning(2)
                .foregroundStyle(settled ? Color.voltText : Color.accentText)
                .animation(Motion.snap, value: settled)
            HStack(spacing: 16) {
                reel(label: "TEAM", value: displayedTeam, locked: teamLocked)
                reel(label: "YEAR", value: displayedYear, locked: yearLocked)
            }
            Text("LOCKED IN")
                .font(.custom(FontName.condBlack, size: 22))
                .kerning(3)
                .foregroundStyle(Color.onVolt)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Color.voltFill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.borderInk, lineWidth: 3))
                .rotationEffect(.degrees(settled ? -4 : -14))
                .scaleEffect(settled ? 1 : 0.3)
                .opacity(settled ? 1 : 0)
                .animation(Motion.overshoot, value: settled)
            marqueeLights
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: 60)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                lightsPhase = true
            }
            spin()
        }
    }

    /// A casino-sign row of chasing lights: alternating blue/volt bulbs blinking in
    /// counter-phase while the reels roll, all steady-on volt once the spin settles.
    private var marqueeLights: some View {
        HStack(spacing: 10) {
            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .fill(settled ? Color.voltFill : (i.isMultiple(of: 2) ? Color.accentFill : Color.voltFill))
                    .frame(width: 10, height: 10)
                    .opacity(settled ? 1 : (i.isMultiple(of: 2) == lightsPhase ? 1 : 0.25))
                    .shadow(color: (settled || i.isMultiple(of: 2) == lightsPhase)
                            ? Color.voltFill.opacity(0.8) : .clear, radius: 5)
            }
        }
        .animation(Motion.snap, value: settled)
    }

    private func reel(label: String, value: String, locked: Bool) -> some View {
        VStack(spacing: 8) {
            Text(label).font(.label11).kerning(1.5)
                .foregroundStyle(locked ? Color.voltText : Color.textMuted)
            Text(value.uppercased())
                .font(.custom(FontName.condBlack, size: 34))
                .foregroundStyle(locked ? Color.textPrimary : Color.textMuted)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(minWidth: 104)
                .id(value)   // new identity per tick so the roll transition fires
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .frame(minHeight: 104)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(locked ? Color.voltFill : Color.borderInk, lineWidth: locked ? 4 : 3))
        .shadow(color: locked ? Color.voltFill.opacity(0.55) : .clear, radius: locked ? 14 : 0)
        .scaleEffect(locked ? 1.06 : 1.0)
        .animation(Motion.overshoot, value: locked)
    }

    private func spin() {
        guard !DebugLaunch.autoOpenDraftSpin else {
            displayedTeam = team; displayedYear = year
            teamLocked = true; yearLocked = true
            // `-screenshotDraftSpinReveal`: freeze here so the settled casino styling
            // (glow, marquee, LOCKED IN stamp) is what the screenshot captures.
            if !DebugLaunch.holdDraftSpinReveal {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { onFinished() }
            }
            return
        }
        tick(remaining: totalTicks + staggerTicks)
    }

    private func tick(remaining: Int) {
        // Team reel locks `staggerTicks` before the year reel — the anticipation beat.
        if !teamLocked && remaining <= staggerTicks {
            displayedTeam = team
            teamLocked = true
            Haptics.commit()
        }
        guard remaining > 0 else {
            displayedYear = year
            yearLocked = true
            confetti += 1
            Haptics.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onFinished() }
            return
        }
        withAnimation(.linear(duration: 0.06)) {
            if !teamLocked { displayedTeam = decoyTeams.randomElement() ?? team }
            displayedYear = decoyYears.randomElement() ?? year
        }
        Haptics.tap()
        // Decelerate toward the landing tick — the classic slot-machine slow-down.
        let elapsed = (totalTicks + staggerTicks) - remaining
        let delay = 0.05 + Double(elapsed) * 0.013
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tick(remaining: remaining - 1) }
    }
}
