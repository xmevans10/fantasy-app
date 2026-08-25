import SwiftUI

/// The end of a blitz run — **and the first and only time the player sees a score in this mode**.
///
/// Everything here is derived from `BlitzRunSummary`, which is built after the clock stops. That
/// is deliberate: the running total genuinely does not exist while a run is in progress (see
/// `BlitzSession`, which has no score property for a board to read), so "score at the end only"
/// is a property of the code rather than a rule the UI is trusted to follow.
///
/// The per-format breakdown carries most of the value. A single blitz number can't say whether
/// you banked it on eight Over/Unders or one flawless sort, and "where did that come from" is the
/// question a player actually has when the confetti stops.
struct BlitzResultView: View {
    let summary: BlitzRunSummary
    let highScore: Int
    let beatHighScore: Bool
    /// True when the player tapped out of a board rather than playing the clock down. Changes
    /// only the headline: "TIME" over a run that was quit is a small lie, and the two endings
    /// feel different enough that the screen should know which one it is.
    var endedEarly: Bool = false
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onPlayAgain: () -> Void
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @State private var confetti = 0

    private var ink: Color { beatHighScore ? .onVolt : .onAccent }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    statRow.heroReveal(1)
                    if !summary.rounds.isEmpty { formatBreakdown.heroReveal(2) }
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(3) }
                    shareRow.heroReveal(4)
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: beatHighScore ? 90 : 40)
        .onAppear { if beatHighScore || summary.bestStreak >= 3 { confetti += 1 } }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(beatHighScore ? "NEW BLITZ BEST" : (endedEarly ? "RUN ENDED" : "TIME"))
                .font(.heading)
                .foregroundStyle(ink.opacity(0.85))
            CountUpText(value: summary.total, font: .heroNumber, color: ink)
            // Spelled out as a ternary rather than interpolated — `Text("\(n) puzzles")` reads
            // "1 puzzles", and this line sits directly under the headline number where it's the
            // most-read sentence on the screen.
            Text(summary.played == 1
                 ? String(localized: "1 puzzle · \(summary.cleared) clean")
                 : String(localized: "\(summary.played) puzzles · \(summary.cleared) clean"))
                .font(.label12)
                .foregroundStyle(ink.opacity(0.75))
            if !beatHighScore && highScore > 0 {
                Text(String(localized: "\(summary.config.duration.minutes) MIN BEST: \(highScore)"))
                    .font(.label11)
                    .foregroundStyle(ink.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: beatHighScore ? .voltFill : .accentFill)
    }

    private var statRow: some View {
        HStack(spacing: 0) {
            // "BEST STREAK", not "BEST RUN" — on a screen that already says "run" three times,
            // "BEST RUN" reads as a personal best rather than as this run's longest clean streak.
            stat(String(localized: "BEST STREAK"), "\(summary.bestStreak)")
            stat(String(localized: "ACCURACY"),
                 summary.accuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
            // Seconds per board, the pace number a blitz is actually about. Suppressed rather
            // than rendered as "0s" on a run that served nothing.
            stat(String(localized: "PER BOARD"),
                 summary.played > 0
                 ? String(format: "%.0fs", summary.elapsed / Double(summary.played)) : "—")
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.custom(FontName.condBlack, size: 22)).foregroundStyle(Color.textPrimary)
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var formatBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHERE IT CAME FROM").font(.label12).foregroundStyle(Color.accentText)
            ForEach(summary.byFormat, id: \.format) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.format.symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(row.format.onTint)
                        .frame(width: 26, height: 26)
                        .background(row.format.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(row.format.displayName)
                        .font(.bodyStrong).foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // "×3" rather than "3 played": plural-free by construction, and narrow
                    // enough that a long format name never has to shrink to fit beside it.
                    Text("×\(row.played)")
                        .font(.label11).foregroundStyle(Color.textMuted)
                        .accessibilityLabel(row.played == 1
                                            ? String(localized: "1 board")
                                            : String(localized: "\(row.played) boards"))
                    Text("\(row.points)")
                        .font(.custom(FontName.condBlack, size: 17))
                        .monospacedDigit()
                        .foregroundStyle(Color.textPrimary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// A plain score brag, not a challenge link — for exactly the reason Over/Under's is: a blitz
    /// deals a different random sequence of boards to every device, so there is no shared board to
    /// dare anyone onto and `ChallengeLink` has nothing to address.
    static func shareText(summary: BlitzRunSummary, beatHighScore: Bool) -> String {
        let minutes = summary.config.duration.minutes
        let headline = beatHighScore
            ? "New personal best: \(summary.total) in a \(minutes)-minute Puzzle Blitz."
            : "\(summary.cleared) of \(summary.played) puzzles in \(minutes) minutes."
        return ShareMessage.compose(
            headline: headline,
            detail: "\(ShareMessage.points(summary.total)) pts across \(summary.config.orderedFormats.count) formats. Beat it.",
            campaign: "res_blitz_\(minutes)m")
    }

    private var shareRow: some View {
        ShareLink(item: Self.shareText(summary: summary, beatHighScore: beatHighScore)) {
            Label("SHARE RUN", systemImage: "square.and.arrow.up").ctaLabel()
        }
        .buttonStyle(PrimePressStyle())
        // ShareLink has no tap callback — a simultaneous gesture is the standard hook.
        .simultaneousGesture(TapGesture().onEnded {
            container.track(.shareTapped, AnalyticsEvent.shareProperties(
                surface: "blitz_result", format: "blitz", artifact: .challengeText,
                extra: ["minutes": String(summary.config.duration.minutes),
                        "played": String(summary.played)]))
        })
    }

    /// PLAY AGAIN sits beside DONE rather than replacing it: the whole point of a fixed-length
    /// run is that the next one starts immediately, and sending the player back to Home to find
    /// the tile again is friction with nothing on the other side of it.
    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            HStack(spacing: 10) {
                Button(action: onDone) {
                    Text("DONE")
                        .font(.heading)
                        .foregroundStyle(Color.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)

                Button(action: onPlayAgain) {
                    Text("PLAY AGAIN").ctaLabel()
                }
                .buttonStyle(PrimePressStyle())
            }
            .padding(16)
            .background(Color.surface)
        }
    }
}
