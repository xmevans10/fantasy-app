import XCTest
import SwiftUI
@testable import BallIQ

/// Renders the new duel surfaces so they can actually be looked at (AGENTS.md §5 — a green
/// build proves the code compiles, not that it looks right).
///
/// Deliberately renders the **outlier** states rather than the happy one: the longest bot name
/// next to a live score next to a clock (the widest the duel bar ever gets), the urgent
/// sub-10-second state, a locked rung, a boss rung, and a standings-length username. Same
/// pattern as `PaywallGalleryTests`/`GridBoardGalleryTests`: writes PNGs to tmp and prints the
/// paths under a grep-able prefix.
@MainActor
final class DuelGalleryTests: XCTestCase {

    private func bot(_ name: String, avatar: String = "🎙️") -> LadderBot {
        LadderBot(id: "b", name: name, avatar: avatar,
                  tagline: "Has an opinion, and a graph to back it.",
                  baseSkill: 0.7, persona: "Talks through every pick.")
    }

    private func rung(_ n: Int, tier: LadderRung.Tier, mode: PuzzleFormat = .grid,
                      boss: Bool = false, seconds: Int = 107) -> LadderRung {
        LadderRung(rung: n, tier: tier, mode: mode, sport: .baseball,
                   puzzleId: "grid-baseball-2026-07-08", botId: "b", botSkill: 0.7,
                   timeLimitSeconds: seconds, seed: 99, isBoss: boss)
    }

    private func run(correct: Int, outOf: Int) -> BotRun {
        BotRun(performance: Double(correct) / Double(outOf), correct: correct, outOf: outOf,
               beats: (0..<outOf).map { BotBeat(at: Double($0) * 6 + 3, index: $0,
                                                correct: $0 < correct) })
    }

    /// The duel clock in every shape it takes.
    func testRenderDuelTimerBarStates() throws {
        let ladderSession = DuelSession(
            challengeID: 27, format: .grid, boardID: "grid-nba-2026-08-02",
            opponentUserID: nil, opponentName: nil, secondsRemaining: 107,
            // Longest real bot name in the seeded content, against a 9-cell board — the widest
            // this bar ever has to be.
            ladder: LadderRunSession(rung: rung(27, tier: .gold), bot: bot("The Archivist", avatar: "📼"),
                                     run: run(correct: 6, outOf: 9)))
        let states: [(String, DuelSession)] = [
            ("human-comfortable", DuelSession(challengeID: 1, format: .keep4, boardID: "p",
                                              opponentUserID: nil, opponentName: "basketballguy2011",
                                              secondsRemaining: 95)),
            ("human-no-username", DuelSession(challengeID: 2, format: .grid, boardID: "p",
                                              opponentUserID: nil, opponentName: nil,
                                              secondsRemaining: 44)),
            // Under the 10s threshold: red fill, pulsing.
            ("human-urgent", DuelSession(challengeID: 3, format: .whoami, boardID: "p",
                                         opponentUserID: nil, opponentName: "kate",
                                         secondsRemaining: 7)),
            ("ladder-live-bot-score", ladderSession),
        ]
        let stack = VStack(spacing: 10) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.0).font(.system(size: 9)).foregroundStyle(Color.textMuted)
                    DuelTimerBar(session: state.1) {}
                }
            }
        }
        .padding(12)
        .frame(width: 393)
        .background(Color.appBackground)

        try render(stack, named: "duel_timer_bar")
    }

    /// A ladder row in all three lock states, plus a boss.
    func testRenderLadderRowStates() throws {
        let rows: [(String, LadderRungRow)] = [
            ("cleared", LadderRungRow(rung: rung(1, tier: .bronze, mode: .keep4, seconds: 120),
                                      bot: bot("The Rookie", avatar: "🐣"), state: .cleared)),
            ("open", LadderRungRow(rung: rung(2, tier: .bronze, mode: .whoami, seconds: 80),
                                   bot: bot("Stat Head", avatar: "📊"), state: .open)),
            ("locked", LadderRungRow(rung: rung(3, tier: .silver, mode: .grid, seconds: 141),
                                     bot: bot("The Analyst"), state: .locked)),
            ("boss (longest name + badge + clock)",
             LadderRungRow(rung: rung(30, tier: .gold, mode: .grid, boss: true, seconds: 99),
                           bot: bot("The Archivist", avatar: "📼"), state: .locked)),
        ]
        let stack = VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0).font(.system(size: 9)).foregroundStyle(Color.textMuted)
                    LadderRowPreview(row: row.1)
                }
            }
        }
        .padding(12)
        .frame(width: 393)
        .background(Color.appBackground)

        try render(stack, named: "ladder_rows")
    }

    private func render<V: View>(_ view: V, named: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer produced nothing")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(named).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("DUEL_GALLERY: \(url.path)")
    }
}

/// A standalone copy of `LadderView`'s row, purely so the gallery can render one without
/// standing up the whole screen (which needs a `NavigationStack`, a container, and a network
/// fetch). Kept next to the test that uses it rather than exported from the view, because
/// making the real row internal-visible would be changing shipping code to suit a screenshot.
private struct LadderRowPreview: View {
    let row: LadderRungRow

    var body: some View {
        let locked = row.state == .locked
        HStack(spacing: 12) {
            Text("\(row.rung.rung)")
                .font(.custom(FontName.condBlack, size: 18))
                .monospacedDigit()
                .foregroundStyle(row.state == .cleared ? row.rung.tier.onTint : Color.textPrimary)
                .frame(width: 34, height: 34)
                .background(row.state == .cleared ? row.rung.tier.tint : Color.surfaceMuted)
                .clipShape(Circle())
            Text(locked ? "🔒" : row.bot.avatar).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.bot.name).font(.bodyStrong).foregroundStyle(Color.textPrimary).lineLimit(1)
                    if row.rung.isBoss {
                        Text("BOSS")
                            .font(.custom(FontName.condBlack, size: 10))
                            .foregroundStyle(Color.onDanger)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.dangerFill).clipShape(Capsule())
                    }
                }
                Text(row.boardLine).font(.label11).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Label(DuelSession.clockText(row.rung.timeLimitSeconds), systemImage: "timer")
                    .font(.label11).monospacedDigit().foregroundStyle(Color.textMuted)
                if row.state == .cleared {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.successText)
                } else if row.state == .open {
                    Text("PLAY")
                        .font(.custom(FontName.condBlack, size: 12))
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.accentFill).clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .opacity(locked ? 0.45 : 1)
        .cardSurface()
    }
}
