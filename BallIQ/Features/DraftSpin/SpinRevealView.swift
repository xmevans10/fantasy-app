import SwiftUI

/// The "slot machine" moment: before showing a round's real roster, cycle two reels (team, year)
/// through decoy values at decelerating speed before landing on the real spun combo — the juice
/// that makes "spin" feel like an actual spin, not static text just appearing.
/// Skips straight to the settled state under any of the `-screenshotDraftSpin*` debug flags,
/// so automated screenshots reliably land on the draft board/result, not mid-animation.
struct SpinRevealView: View {
    let team: String
    let year: String
    let onFinished: () -> Void

    @State private var displayedTeam: String
    @State private var displayedYear: String
    @State private var settled = false

    private let decoyTeams: [String]
    private let decoyYears: [String]
    private let totalTicks = 14

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
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let length = max(text.count, 2)
        return (0..<8).map { _ in String((0..<length).map { _ in letters.randomElement() ?? "X" }) }
    }

    var body: some View {
        VStack(spacing: 22) {
            Text("SPINNING…").font(.label12).foregroundStyle(Color.accentText)
            HStack(spacing: 16) {
                reel(displayedTeam)
                reel(displayedYear)
            }
            Text(settled ? "LOCKED IN" : " ")
                .font(.label11).foregroundStyle(Color.successText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .onAppear { spin() }
    }

    private func reel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom(FontName.condBlack, size: 28))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(minWidth: 96)
            .padding(.horizontal, 14).padding(.vertical, 16)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 3))
            .scaleEffect(settled ? 1.08 : 1.0)
            .animation(Motion.snap, value: settled)
    }

    private func spin() {
        guard !DebugLaunch.autoOpenDraftSpin else {
            displayedTeam = team; displayedYear = year; settled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { onFinished() }
            return
        }
        tick(remaining: totalTicks)
    }

    private func tick(remaining: Int) {
        guard remaining > 0 else {
            Haptics.tap()
            displayedTeam = team
            displayedYear = year
            settled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onFinished() }
            return
        }
        displayedTeam = decoyTeams.randomElement() ?? team
        displayedYear = decoyYears.randomElement() ?? year
        Haptics.tap()
        // Decelerate toward the landing tick — the classic slot-machine slow-down.
        let delay = 0.05 + (Double(totalTicks - remaining) * 0.012)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tick(remaining: remaining - 1) }
    }
}
